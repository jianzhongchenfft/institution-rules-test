-- V5.2 評估管理：高負荷家庭照顧者初篩
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-02
-- form_code 沿用 caregiver_burden
-- 指標版本：衛福部高負荷家庭照顧者初篩指標（112-12-22 二修）

create table if not exists public.assessment_caregiver_screen_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  applicability text not null default 'applicable',
  caregiver_info jsonb not null default '{}'::jsonb,
  answers jsonb not null default '{}'::jsonb,
  notes jsonb not null default '{}'::jsonb,
  summary jsonb not null default '{}'::jsonb,
  indicator_version text not null default 'MOHW-112-12-22',
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint assessment_caregiver_screen_applicability_chk
    check (applicability in ('applicable','no_family_caregiver','paid_caregiver','unable'))
);

create index if not exists assessment_caregiver_screen_case_idx
  on public.assessment_caregiver_screen_records(case_id);
create index if not exists assessment_caregiver_screen_event_idx
  on public.assessment_caregiver_screen_records(assessment_event_id);
create index if not exists assessment_caregiver_screen_confirmed_idx
  on public.assessment_caregiver_screen_records(confirmed_at);

create table if not exists public.assessment_caregiver_screen_history (
  id uuid primary key default gen_random_uuid(),
  caregiver_screen_record_id uuid not null references public.assessment_caregiver_screen_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_caregiver_screen_history_record_idx
  on public.assessment_caregiver_screen_history(caregiver_screen_record_id,changed_at);
create index if not exists assessment_caregiver_screen_history_case_idx
  on public.assessment_caregiver_screen_history(case_id,changed_at);

alter table public.assessment_caregiver_screen_records enable row level security;
alter table public.assessment_caregiver_screen_history enable row level security;

drop policy if exists assessment_caregiver_screen_read on public.assessment_caregiver_screen_records;
create policy assessment_caregiver_screen_read
on public.assessment_caregiver_screen_records
for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_caregiver_screen_insert on public.assessment_caregiver_screen_records;
create policy assessment_caregiver_screen_insert
on public.assessment_caregiver_screen_records
for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_caregiver_screen_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_caregiver_screen_update on public.assessment_caregiver_screen_records;
create policy assessment_caregiver_screen_update
on public.assessment_caregiver_screen_records
for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_caregiver_screen_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_caregiver_screen_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_caregiver_screen_history_read on public.assessment_caregiver_screen_history;
create policy assessment_caregiver_screen_history_read
on public.assessment_caregiver_screen_history
for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_caregiver_screen_history_insert on public.assessment_caregiver_screen_history;
create policy assessment_caregiver_screen_history_insert
on public.assessment_caregiver_screen_history
for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_caregiver_screen_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_caregiver_screen_records from public,anon,authenticated;
revoke all on public.assessment_caregiver_screen_history from public,anon,authenticated;
grant select,insert,update on public.assessment_caregiver_screen_records to authenticated;
grant select,insert on public.assessment_caregiver_screen_history to authenticated;
grant all on public.assessment_caregiver_screen_records to service_role;
grant all on public.assessment_caregiver_screen_history to service_role;

create or replace function public.save_assessment_caregiver_screen(
  p_event_id uuid,
  p_applicability text,
  p_caregiver_info jsonb,
  p_answers jsonb,
  p_notes jsonb,
  p_summary jsonb,
  p_finalize boolean default false
)
returns public.assessment_caregiver_screen_records
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_old public.assessment_caregiver_screen_records;
  v_record public.assessment_caregiver_screen_records;
  v_key text;
  v_value text;
  v_positive_count int:=0;
  v_referral_required boolean:=false;
  v_form_status text;
  v_indicator_keys text[]:=array[
    'behavior_stress','older_caregiver','limited_experience','no_relief',
    'multiple_dependents','caregiver_health','resource_financial_crisis',
    'recent_care_change','violence_neglect_risk','suicide_risk'
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
    where f.assessment_event_id=p_event_id and f.form_code='caregiver_burden'
  ) then raise exception 'CAREGIVER_SCREEN_FORM_NOT_SELECTED'; end if;

  p_applicability:=coalesce(nullif(p_applicability,''),'applicable');
  p_caregiver_info:=coalesce(p_caregiver_info,'{}'::jsonb);
  p_answers:=coalesce(p_answers,'{}'::jsonb);
  p_notes:=coalesce(p_notes,'{}'::jsonb);
  p_summary:=coalesce(p_summary,'{}'::jsonb);

  if p_applicability not in ('applicable','no_family_caregiver','paid_caregiver','unable') then
    raise exception 'INVALID_CAREGIVER_SCREEN_APPLICABILITY';
  end if;
  if jsonb_typeof(p_caregiver_info)<>'object' or jsonb_typeof(p_answers)<>'object'
     or jsonb_typeof(p_notes)<>'object' or jsonb_typeof(p_summary)<>'object' then
    raise exception 'INVALID_CAREGIVER_SCREEN_JSON';
  end if;

  if p_applicability='applicable' then
    foreach v_key in array v_indicator_keys loop
      v_value:=p_answers->>v_key;
      if v_value is not null and v_value not in ('yes','no') then
        raise exception 'INVALID_CAREGIVER_SCREEN_ANSWER:%',v_key;
      end if;
      if p_finalize and v_value is null then
        raise exception 'CAREGIVER_SCREEN_INCOMPLETE:%',v_key;
      end if;
      if v_value='yes' then
        v_positive_count:=v_positive_count+1;
        if p_finalize and nullif(btrim(coalesce(p_notes->>v_key,'')),'') is null then
          raise exception 'CAREGIVER_SCREEN_NOTE_REQUIRED:%',v_key;
        end if;
      end if;
    end loop;

    v_referral_required:=v_positive_count>=2
      or p_answers->>'violence_neglect_risk'='yes'
      or p_answers->>'suicide_risk'='yes'
      or coalesce((p_summary->>'professional_referral')::boolean,false);

    if p_finalize then
      if nullif(btrim(coalesce(p_caregiver_info->>'name','')),'') is null
         or nullif(btrim(coalesce(p_caregiver_info->>'relation','')),'') is null then
        raise exception 'CAREGIVER_SCREEN_CAREGIVER_INFO_REQUIRED';
      end if;
      if v_referral_required then
        if coalesce(p_summary->>'referral_action','') not in ('planned','referred','declined_followup','other') then
          raise exception 'CAREGIVER_SCREEN_REFERRAL_ACTION_REQUIRED';
        end if;
        if nullif(btrim(coalesce(p_summary->>'action_note','')),'') is null then
          raise exception 'CAREGIVER_SCREEN_ACTION_NOTE_REQUIRED';
        end if;
      end if;
      if coalesce((p_summary->>'professional_referral')::boolean,false)
         and nullif(btrim(coalesce(p_summary->>'professional_reason','')),'') is null then
        raise exception 'CAREGIVER_SCREEN_PROFESSIONAL_REASON_REQUIRED';
      end if;
    end if;
  elsif p_finalize then
    if p_applicability='unable'
       and nullif(btrim(coalesce(p_summary->>'unable_reason','')),'') is null then
      raise exception 'CAREGIVER_SCREEN_UNABLE_REASON_REQUIRED';
    end if;
  end if;

  p_summary:=p_summary||jsonb_build_object(
    'positive_count',v_positive_count,
    'referral_required',v_referral_required
  );

  select * into v_old
  from public.assessment_caregiver_screen_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_caregiver_screen_records(
      assessment_event_id,case_id,applicability,caregiver_info,answers,notes,summary,
      confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_applicability,p_caregiver_info,p_answers,p_notes,p_summary,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    ) returning * into v_record;
  else
    if to_jsonb(v_old.applicability) is distinct from to_jsonb(p_applicability) then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'applicability',to_jsonb(v_old.applicability),to_jsonb(p_applicability),(select auth.uid()));
    end if;
    if v_old.caregiver_info is distinct from p_caregiver_info then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'caregiver_info',v_old.caregiver_info,p_caregiver_info,(select auth.uid()));
    end if;
    if v_old.answers is distinct from p_answers then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'answers',v_old.answers,p_answers,(select auth.uid()));
    end if;
    if v_old.notes is distinct from p_notes then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'notes',v_old.notes,p_notes,(select auth.uid()));
    end if;
    if v_old.summary is distinct from p_summary then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'summary',v_old.summary,p_summary,(select auth.uid()));
    end if;

    update public.assessment_caregiver_screen_records
    set applicability=p_applicability,
        caregiver_info=p_caregiver_info,
        answers=p_answers,
        notes=p_notes,
        summary=p_summary,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  v_form_status:=case
    when not p_finalize then 'in_progress'
    when p_applicability in ('no_family_caregiver','paid_caregiver') then 'not_applicable'
    when p_applicability='unable' then 'unable'
    else 'completed'
  end;

  update public.assessment_event_forms
  set status=v_form_status,updated_at=now()
  where assessment_event_id=p_event_id and form_code='caregiver_burden';

  update public.assessment_events
  set status=case
        when p_finalize and not exists (
          select 1 from public.assessment_event_forms f
          where f.assessment_event_id=p_event_id
            and f.status not in ('completed','unable','not_applicable')
        ) then 'forms_completed'
        when status='pending' then 'in_progress'
        else status
      end,
      started_at=coalesce(started_at,now()),
      forms_completed_at=case
        when p_finalize and not exists (
          select 1 from public.assessment_event_forms f
          where f.assessment_event_id=p_event_id
            and f.status not in ('completed','unable','not_applicable')
        ) then coalesce(forms_completed_at,now())
        else forms_completed_at
      end,
      updated_by=(select auth.uid()),
      updated_at=now()
  where id=p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_caregiver_screen(uuid,text,jsonb,jsonb,jsonb,jsonb,boolean) from public,anon;
grant execute on function public.save_assessment_caregiver_screen(uuid,text,jsonb,jsonb,jsonb,jsonb,boolean) to authenticated;
