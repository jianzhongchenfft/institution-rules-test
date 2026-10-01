-- V5.2 評估管理：支持系統
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-02
-- 內容：家庭／照顧安排、7個支持面向、經濟與社會資源、前次帶入、歷程與儲存 RPC

create table if not exists public.assessment_support_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  household jsonb not null default '{}'::jsonb,
  family_members jsonb not null default '[]'::jsonb,
  support_domains jsonb not null default '{}'::jsonb,
  resources jsonb not null default '{}'::jsonb,
  summary jsonb not null default '{}'::jsonb,
  copied_from_id uuid references public.assessment_support_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_support_records_case_id_idx on public.assessment_support_records(case_id);
create index if not exists assessment_support_records_event_id_idx on public.assessment_support_records(assessment_event_id);
create index if not exists assessment_support_records_confirmed_at_idx on public.assessment_support_records(confirmed_at);
create index if not exists assessment_support_records_copied_from_id_idx on public.assessment_support_records(copied_from_id);

create table if not exists public.assessment_support_history (
  id uuid primary key default gen_random_uuid(),
  support_record_id uuid not null references public.assessment_support_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_support_history_record_idx on public.assessment_support_history(support_record_id, changed_at);
create index if not exists assessment_support_history_case_idx on public.assessment_support_history(case_id, changed_at);
create index if not exists assessment_support_history_event_idx on public.assessment_support_history(assessment_event_id);

alter table public.assessment_support_records enable row level security;
alter table public.assessment_support_history enable row level security;

drop policy if exists assessment_support_read on public.assessment_support_records;
create policy assessment_support_read on public.assessment_support_records
for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_support_insert on public.assessment_support_records;
create policy assessment_support_insert on public.assessment_support_records
for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_support_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_support_update on public.assessment_support_records;
create policy assessment_support_update on public.assessment_support_records
for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_support_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_support_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_support_history_read on public.assessment_support_history;
create policy assessment_support_history_read on public.assessment_support_history
for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_support_history_insert on public.assessment_support_history;
create policy assessment_support_history_insert on public.assessment_support_history
for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_support_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_support_records from public,anon,authenticated;
revoke all on public.assessment_support_history from public,anon,authenticated;
grant select,insert,update on public.assessment_support_records to authenticated;
grant select,insert on public.assessment_support_history to authenticated;
grant all on public.assessment_support_records to service_role;
grant all on public.assessment_support_history to service_role;

create or replace function public.save_assessment_support(
  p_event_id uuid,
  p_household jsonb,
  p_family_members jsonb,
  p_support_domains jsonb,
  p_resources jsonb,
  p_summary jsonb,
  p_finalize boolean default false,
  p_copied_from_id uuid default null
)
returns public.assessment_support_records
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_support_records;
  v_old public.assessment_support_records;
  v_key text;
  v_status text;
  v_domain_keys text[]:=array[
    'daily_care','meal_housework','medical_transport','medication_health',
    'financial','emotional','decision_contact'
  ];
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='support'
  ) then raise exception 'SUPPORT_FORM_NOT_SELECTED'; end if;

  p_household:=coalesce(p_household,'{}'::jsonb);
  p_family_members:=coalesce(p_family_members,'[]'::jsonb);
  p_support_domains:=coalesce(p_support_domains,'{}'::jsonb);
  p_resources:=coalesce(p_resources,'{}'::jsonb);
  p_summary:=coalesce(p_summary,'{}'::jsonb);

  if jsonb_typeof(p_household)<>'object' then raise exception 'INVALID_SUPPORT_HOUSEHOLD'; end if;
  if jsonb_typeof(p_family_members)<>'array' then raise exception 'INVALID_SUPPORT_FAMILY_MEMBERS'; end if;
  if jsonb_typeof(p_support_domains)<>'object' then raise exception 'INVALID_SUPPORT_DOMAINS'; end if;
  if jsonb_typeof(p_resources)<>'object' then raise exception 'INVALID_SUPPORT_RESOURCES'; end if;
  if jsonb_typeof(p_summary)<>'object' then raise exception 'INVALID_SUPPORT_SUMMARY'; end if;

  foreach v_key in array v_domain_keys loop
    if p_support_domains ? v_key then
      v_status:=p_support_domains->v_key->>'status';
      if v_status is not null and v_status not in ('adequate','partial','insufficient','not_applicable') then
        raise exception 'INVALID_SUPPORT_DOMAIN:%',v_key;
      end if;
      if p_finalize and v_status is null then
        raise exception 'SUPPORT_DOMAIN_INCOMPLETE:%',v_key;
      end if;
      if p_finalize
         and v_status in ('partial','insufficient','not_applicable')
         and nullif(btrim(coalesce(p_support_domains->v_key->>'note','')),'') is null then
        raise exception 'SUPPORT_DOMAIN_NOTE_REQUIRED:%',v_key;
      end if;
    elsif p_finalize then
      raise exception 'SUPPORT_DOMAIN_INCOMPLETE:%',v_key;
    end if;
  end loop;

  if p_finalize then
    if nullif(btrim(coalesce(p_household->>'living_arrangement','')),'') is null then raise exception 'SUPPORT_LIVING_ARRANGEMENT_REQUIRED'; end if;
    if coalesce(p_household->>'primary_caregiver_status','') not in ('present','none') then raise exception 'SUPPORT_PRIMARY_CAREGIVER_STATUS_REQUIRED'; end if;
    if p_household->>'primary_caregiver_status'='present' then
      if nullif(btrim(coalesce(p_household->>'primary_caregiver_name','')),'') is null
         or nullif(btrim(coalesce(p_household->>'primary_caregiver_relation','')),'') is null then
        raise exception 'SUPPORT_PRIMARY_CAREGIVER_INFO_REQUIRED';
      end if;
    end if;
    if coalesce(p_resources->>'economic_status','') not in ('stable','watch','difficulty') then raise exception 'SUPPORT_ECONOMIC_STATUS_REQUIRED'; end if;
    if (p_resources->>'economic_status') in ('watch','difficulty')
       and nullif(btrim(coalesce(p_resources->>'economic_note','')),'') is null then raise exception 'SUPPORT_ECONOMIC_NOTE_REQUIRED'; end if;
    if coalesce(p_summary->>'overall_support','') not in ('adequate','needs_attention','weak') then raise exception 'SUPPORT_OVERALL_REQUIRED'; end if;
    if (p_summary->>'overall_support') in ('needs_attention','weak')
       and nullif(btrim(coalesce(p_summary->>'key_issues','')),'') is null then raise exception 'SUPPORT_KEY_ISSUES_REQUIRED'; end if;
    if coalesce(p_summary->>'followup_required','') not in ('yes','no') then raise exception 'SUPPORT_FOLLOWUP_REQUIRED'; end if;
    if p_summary->>'followup_required'='yes'
       and nullif(btrim(coalesce(p_summary->>'followup_note','')),'') is null then raise exception 'SUPPORT_FOLLOWUP_NOTE_REQUIRED'; end if;
  end if;

  select * into v_old from public.assessment_support_records where assessment_event_id=p_event_id for update;

  if v_old.id is null then
    insert into public.assessment_support_records(
      assessment_event_id,case_id,household,family_members,support_domains,resources,summary,
      copied_from_id,copied_at,confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_household,p_family_members,p_support_domains,p_resources,p_summary,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    ) returning * into v_record;
  else
    if v_old.household is distinct from p_household then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'household',v_old.household,p_household,(select auth.uid()));
    end if;
    if v_old.family_members is distinct from p_family_members then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'family_members',v_old.family_members,p_family_members,(select auth.uid()));
    end if;
    if v_old.support_domains is distinct from p_support_domains then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'support_domains',v_old.support_domains,p_support_domains,(select auth.uid()));
    end if;
    if v_old.resources is distinct from p_resources then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'resources',v_old.resources,p_resources,(select auth.uid()));
    end if;
    if v_old.summary is distinct from p_summary then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'summary',v_old.summary,p_summary,(select auth.uid()));
    end if;

    update public.assessment_support_records
    set household=p_household,
        family_members=p_family_members,
        support_domains=p_support_domains,
        resources=p_resources,
        summary=p_summary,
        copied_from_id=coalesce(p_copied_from_id,copied_from_id),
        copied_at=case when p_copied_from_id is not null and p_copied_from_id is distinct from copied_from_id then now() else copied_at end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case when p_finalize then 'completed' else 'in_progress' end,updated_at=now()
  where assessment_event_id=p_event_id and form_code='support' and (p_finalize or status<>'completed');

  update public.assessment_events
  set status=case
        when p_finalize and not exists (
          select 1 from public.assessment_event_forms f
          where f.assessment_event_id=p_event_id and f.status not in ('completed','unable','not_applicable')
        ) then 'forms_completed'
        when status='pending' then 'in_progress'
        else status
      end,
      started_at=coalesce(started_at,now()),
      forms_completed_at=case
        when p_finalize and not exists (
          select 1 from public.assessment_event_forms f
          where f.assessment_event_id=p_event_id and f.status not in ('completed','unable','not_applicable')
        ) then coalesce(forms_completed_at,now())
        else forms_completed_at
      end,
      updated_by=(select auth.uid()),
      updated_at=now()
  where id=p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_support(uuid,jsonb,jsonb,jsonb,jsonb,jsonb,boolean,uuid) from public,anon;
grant execute on function public.save_assessment_support(uuid,jsonb,jsonb,jsonb,jsonb,jsonb,boolean,uuid) to authenticated;
