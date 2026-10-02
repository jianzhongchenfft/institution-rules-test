-- V5.2 評估管理：整體評估總結
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-02

create table if not exists public.assessment_event_summaries (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  overall_status text,
  key_findings text,
  care_recommendations text,
  followup_required boolean,
  followup_plan text,
  service_adjustment_required boolean,
  service_adjustment_note text,
  external_coordination_required boolean,
  external_coordination_note text,
  completed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint assessment_event_summary_overall_chk
    check (overall_status is null or overall_status in ('stable','attention','intervention'))
);

create index if not exists assessment_event_summaries_case_idx
  on public.assessment_event_summaries(case_id);
create index if not exists assessment_event_summaries_completed_idx
  on public.assessment_event_summaries(completed_at);

create table if not exists public.assessment_event_summary_history (
  id uuid primary key default gen_random_uuid(),
  summary_id uuid not null references public.assessment_event_summaries(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  old_snapshot jsonb not null,
  new_snapshot jsonb not null,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_event_summary_history_summary_idx
  on public.assessment_event_summary_history(summary_id,changed_at);
create index if not exists assessment_event_summary_history_event_idx
  on public.assessment_event_summary_history(assessment_event_id);
create index if not exists assessment_event_summary_history_case_idx
  on public.assessment_event_summary_history(case_id);

alter table public.assessment_event_summaries enable row level security;
alter table public.assessment_event_summary_history enable row level security;

drop policy if exists assessment_event_summaries_read on public.assessment_event_summaries;
create policy assessment_event_summaries_read
on public.assessment_event_summaries
for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_event_summaries_insert on public.assessment_event_summaries;
create policy assessment_event_summaries_insert
on public.assessment_event_summaries
for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_event_summaries.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_summaries_update on public.assessment_event_summaries;
create policy assessment_event_summaries_update
on public.assessment_event_summaries
for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_event_summaries.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_event_summaries.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_summary_history_read on public.assessment_event_summary_history;
create policy assessment_event_summary_history_read
on public.assessment_event_summary_history
for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_event_summary_history_insert on public.assessment_event_summary_history;
create policy assessment_event_summary_history_insert
on public.assessment_event_summary_history
for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_event_summary_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_event_summaries from public,anon,authenticated;
revoke all on public.assessment_event_summary_history from public,anon,authenticated;
grant select,insert,update on public.assessment_event_summaries to authenticated;
grant select,insert on public.assessment_event_summary_history to authenticated;
grant all on public.assessment_event_summaries to service_role;
grant all on public.assessment_event_summary_history to service_role;

create or replace function public.save_assessment_event_summary(
  p_event_id uuid,
  p_overall_status text,
  p_key_findings text,
  p_care_recommendations text,
  p_followup_required boolean,
  p_followup_plan text,
  p_service_adjustment_required boolean,
  p_service_adjustment_note text,
  p_external_coordination_required boolean,
  p_external_coordination_note text,
  p_finalize boolean default false
)
returns public.assessment_event_summaries
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_old public.assessment_event_summaries;
  v_record public.assessment_event_summaries;
  v_old_snapshot jsonb;
  v_new_snapshot jsonb;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;
  if v_event.status='voided' then raise exception 'ASSESSMENT_EVENT_VOIDED'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id
      and f.status not in ('completed','unable','not_applicable')
  ) then
    raise exception 'ASSESSMENT_FORMS_NOT_COMPLETED';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id
  ) then
    raise exception 'ASSESSMENT_FORMS_NOT_FOUND';
  end if;

  if p_overall_status is not null
     and p_overall_status not in ('stable','attention','intervention') then
    raise exception 'INVALID_ASSESSMENT_OVERALL_STATUS';
  end if;

  if p_finalize then
    if p_overall_status is null then raise exception 'ASSESSMENT_OVERALL_STATUS_REQUIRED'; end if;
    if nullif(btrim(coalesce(p_key_findings,'')),'') is null then
      raise exception 'ASSESSMENT_KEY_FINDINGS_REQUIRED';
    end if;
    if nullif(btrim(coalesce(p_care_recommendations,'')),'') is null then
      raise exception 'ASSESSMENT_CARE_RECOMMENDATIONS_REQUIRED';
    end if;
    if p_followup_required is null then raise exception 'ASSESSMENT_FOLLOWUP_DECISION_REQUIRED'; end if;
    if p_service_adjustment_required is null then raise exception 'ASSESSMENT_SERVICE_ADJUSTMENT_DECISION_REQUIRED'; end if;
    if p_external_coordination_required is null then raise exception 'ASSESSMENT_EXTERNAL_COORDINATION_DECISION_REQUIRED'; end if;
    if p_followup_required and nullif(btrim(coalesce(p_followup_plan,'')),'') is null then
      raise exception 'ASSESSMENT_FOLLOWUP_PLAN_REQUIRED';
    end if;
    if p_service_adjustment_required and nullif(btrim(coalesce(p_service_adjustment_note,'')),'') is null then
      raise exception 'ASSESSMENT_SERVICE_ADJUSTMENT_NOTE_REQUIRED';
    end if;
    if p_external_coordination_required and nullif(btrim(coalesce(p_external_coordination_note,'')),'') is null then
      raise exception 'ASSESSMENT_EXTERNAL_COORDINATION_NOTE_REQUIRED';
    end if;
  end if;

  select * into v_old
  from public.assessment_event_summaries
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_event_summaries(
      assessment_event_id,case_id,overall_status,key_findings,care_recommendations,
      followup_required,followup_plan,service_adjustment_required,service_adjustment_note,
      external_coordination_required,external_coordination_note,completed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_overall_status,p_key_findings,p_care_recommendations,
      p_followup_required,p_followup_plan,p_service_adjustment_required,p_service_adjustment_note,
      p_external_coordination_required,p_external_coordination_note,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    ) returning * into v_record;
  else
    v_old_snapshot:=jsonb_build_object(
      'overall_status',v_old.overall_status,
      'key_findings',v_old.key_findings,
      'care_recommendations',v_old.care_recommendations,
      'followup_required',v_old.followup_required,
      'followup_plan',v_old.followup_plan,
      'service_adjustment_required',v_old.service_adjustment_required,
      'service_adjustment_note',v_old.service_adjustment_note,
      'external_coordination_required',v_old.external_coordination_required,
      'external_coordination_note',v_old.external_coordination_note,
      'completed_at',v_old.completed_at
    );

    v_new_snapshot:=jsonb_build_object(
      'overall_status',p_overall_status,
      'key_findings',p_key_findings,
      'care_recommendations',p_care_recommendations,
      'followup_required',p_followup_required,
      'followup_plan',p_followup_plan,
      'service_adjustment_required',p_service_adjustment_required,
      'service_adjustment_note',p_service_adjustment_note,
      'external_coordination_required',p_external_coordination_required,
      'external_coordination_note',p_external_coordination_note,
      'completed_at',case when p_finalize then coalesce(v_old.completed_at,now()) else v_old.completed_at end
    );

    if v_old_snapshot is distinct from v_new_snapshot then
      insert into public.assessment_event_summary_history(
        summary_id,assessment_event_id,case_id,old_snapshot,new_snapshot,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,v_old_snapshot,v_new_snapshot,(select auth.uid())
      );
    end if;

    update public.assessment_event_summaries
    set overall_status=p_overall_status,
        key_findings=p_key_findings,
        care_recommendations=p_care_recommendations,
        followup_required=p_followup_required,
        followup_plan=p_followup_plan,
        service_adjustment_required=p_service_adjustment_required,
        service_adjustment_note=p_service_adjustment_note,
        external_coordination_required=p_external_coordination_required,
        external_coordination_note=p_external_coordination_note,
        completed_at=case when p_finalize then coalesce(completed_at,now()) else completed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  if p_finalize then
    update public.assessment_events
    set status='completed',
        completed_at=coalesce(completed_at,now()),
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=p_event_id;
  end if;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_event_summary(
  uuid,text,text,text,boolean,text,boolean,text,boolean,text,boolean
) from public,anon;
grant execute on function public.save_assessment_event_summary(
  uuid,text,text,text,boolean,text,boolean,text,boolean,text,boolean
) to authenticated;
