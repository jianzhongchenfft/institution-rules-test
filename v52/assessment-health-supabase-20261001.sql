-- V5.2 評估管理：身體與健康狀況評估
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 內容依機構現行「近期就醫與用藥情形」及「身體與健康狀況評估」欄位。

begin;

create table if not exists public.assessment_health_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  medical_info jsonb not null default '{}'::jsonb,
  medication_checks jsonb not null default '{}'::jsonb,
  health_items jsonb not null default '{}'::jsonb,
  health_notes jsonb not null default '{}'::jsonb,
  total_score integer check (total_score between 0 and 20),
  copied_from_id uuid references public.assessment_health_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_health_records_case_id_idx on public.assessment_health_records(case_id);
create index if not exists assessment_health_records_event_id_idx on public.assessment_health_records(assessment_event_id);
create index if not exists assessment_health_records_confirmed_at_idx on public.assessment_health_records(confirmed_at);
create index if not exists assessment_health_records_copied_from_id_idx on public.assessment_health_records(copied_from_id);

create table if not exists public.assessment_health_history (
  id uuid primary key default gen_random_uuid(),
  health_record_id uuid not null references public.assessment_health_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_health_history_record_idx on public.assessment_health_history(health_record_id, changed_at);
create index if not exists assessment_health_history_case_idx on public.assessment_health_history(case_id, changed_at);
create index if not exists assessment_health_history_event_id_idx on public.assessment_health_history(assessment_event_id);

alter table public.assessment_health_records enable row level security;
alter table public.assessment_health_history enable row level security;

drop policy if exists assessment_health_read on public.assessment_health_records;
create policy assessment_health_read on public.assessment_health_records
for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_health_insert on public.assessment_health_records;
create policy assessment_health_insert on public.assessment_health_records
for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_health_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_health_update on public.assessment_health_records;
create policy assessment_health_update on public.assessment_health_records
for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_health_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_health_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_health_history_read on public.assessment_health_history;
create policy assessment_health_history_read on public.assessment_health_history
for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_health_history_insert on public.assessment_health_history;
create policy assessment_health_history_insert on public.assessment_health_history
for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_health_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_health_records from public, anon, authenticated;
revoke all on public.assessment_health_history from public, anon, authenticated;
grant select, insert, update on public.assessment_health_records to authenticated;
grant select, insert on public.assessment_health_history to authenticated;
grant all on public.assessment_health_records to service_role;
grant all on public.assessment_health_history to service_role;

commit;

create or replace function public.save_assessment_health(
  p_event_id uuid,
  p_medical_info jsonb,
  p_medication_checks jsonb,
  p_health_items jsonb,
  p_health_notes jsonb,
  p_finalize boolean default false,
  p_copied_from_id uuid default null
)
returns public.assessment_health_records
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_health_records;
  v_old public.assessment_health_records;
  v_key text;
  v_status text;
  v_total integer:=0;
  v_health_keys text[]:=array[
    'consciousness','eating','elimination','mobility','upper_limb',
    'lower_limb','daily_activity','sleep','appetite_weight','mood'
  ];
  v_med_keys text[]:=array[
    'storage_safety','expired_medicine','medicine_recognition',
    'follow_prescription','medication_management_support'
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
    where f.assessment_event_id=p_event_id and f.form_code='health'
  ) then raise exception 'HEALTH_FORM_NOT_SELECTED'; end if;

  p_medical_info:=coalesce(p_medical_info,'{}'::jsonb);
  p_medication_checks:=coalesce(p_medication_checks,'{}'::jsonb);
  p_health_items:=coalesce(p_health_items,'{}'::jsonb);
  p_health_notes:=coalesce(p_health_notes,'{}'::jsonb);

  if p_medical_info ? 'healthcare_events'
     and jsonb_typeof(p_medical_info->'healthcare_events')<>'array' then
    raise exception 'INVALID_HEALTHCARE_EVENTS';
  end if;

  if p_medical_info ? 'no_healthcare_events'
     and jsonb_typeof(p_medical_info->'no_healthcare_events')<>'boolean' then
    raise exception 'INVALID_NO_HEALTHCARE_EVENTS';
  end if;

  if p_medical_info ? 'no_fixed_medications'
     and jsonb_typeof(p_medical_info->'no_fixed_medications')<>'boolean' then
    raise exception 'INVALID_NO_FIXED_MEDICATIONS';
  end if;

  if p_medical_info ? 'diagnosis_change'
     and p_medical_info->>'diagnosis_change' not in ('no','yes') then
    raise exception 'INVALID_DIAGNOSIS_CHANGE';
  end if;

  if p_medical_info ? 'medication_change'
     and p_medical_info->>'medication_change' not in ('none','changed') then
    raise exception 'INVALID_MEDICATION_CHANGE';
  end if;

  if p_medical_info ? 'medication_method'
     and p_medical_info->>'medication_method' not in ('self','assisted') then
    raise exception 'INVALID_MEDICATION_METHOD';
  end if;

  if p_medical_info ? 'regular_followup'
     and p_medical_info->>'regular_followup' not in ('yes','no') then
    raise exception 'INVALID_REGULAR_FOLLOWUP';
  end if;

  if p_medical_info ? 'medication_regular'
     and p_medical_info->>'medication_regular' not in ('yes','no') then
    raise exception 'INVALID_MEDICATION_REGULAR';
  end if;

  if p_medical_info ? 'side_effect'
     and p_medical_info->>'side_effect' not in ('none','present') then
    raise exception 'INVALID_SIDE_EFFECT';
  end if;

  if p_medical_info ? 'care_impact'
     and p_medical_info->>'care_impact' not in ('no_impact','observe','adjust_plan','contact_external') then
    raise exception 'INVALID_CARE_IMPACT';
  end if;

  foreach v_key in array v_med_keys loop
    if p_medication_checks ? v_key then
      v_status:=p_medication_checks->v_key->>'status';
      if v_status is not null and v_status not in ('good','improve','not_applicable') then
        raise exception 'INVALID_MEDICATION_CHECK:%',v_key;
      end if;
    end if;
  end loop;

  foreach v_key in array v_health_keys loop
    v_status:=p_health_items->>v_key;

    if v_status is not null and v_status not in ('good','observe','refer') then
      raise exception 'INVALID_HEALTH_STATUS:%',v_key;
    end if;

    if p_finalize and v_status is null then
      raise exception 'HEALTH_INCOMPLETE:%',v_key;
    end if;

    if v_status='good' then v_total:=v_total+2;
    elsif v_status='observe' then v_total:=v_total+1;
    end if;
  end loop;

  select * into v_old
  from public.assessment_health_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_health_records(
      assessment_event_id,case_id,medical_info,medication_checks,
      health_items,health_notes,total_score,copied_from_id,copied_at,
      confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_medical_info,p_medication_checks,
      p_health_items,p_health_notes,
      case when p_health_items<>'{}'::jsonb then v_total else null end,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.medical_info,'{}'::jsonb)||p_medical_info) as t(key)
    loop
      if (v_old.medical_info->v_key) is distinct from (p_medical_info->v_key) then
        insert into public.assessment_health_history(
          health_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'medical_info.'||v_key,
          v_old.medical_info->v_key,p_medical_info->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.medication_checks,'{}'::jsonb)||p_medication_checks) as t(key)
    loop
      if (v_old.medication_checks->v_key) is distinct from (p_medication_checks->v_key) then
        insert into public.assessment_health_history(
          health_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'medication_checks.'||v_key,
          v_old.medication_checks->v_key,p_medication_checks->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.health_items,'{}'::jsonb)||p_health_items) as t(key)
    loop
      if (v_old.health_items->v_key) is distinct from (p_health_items->v_key) then
        insert into public.assessment_health_history(
          health_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'health_items.'||v_key,
          v_old.health_items->v_key,p_health_items->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.health_notes,'{}'::jsonb)||p_health_notes) as t(key)
    loop
      if (v_old.health_notes->v_key) is distinct from (p_health_notes->v_key) then
        insert into public.assessment_health_history(
          health_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'health_notes.'||v_key,
          v_old.health_notes->v_key,p_health_notes->v_key,(select auth.uid())
        );
      end if;
    end loop;

    update public.assessment_health_records
    set medical_info=p_medical_info,
        medication_checks=p_medication_checks,
        health_items=p_health_items,
        health_notes=p_health_notes,
        total_score=case when p_health_items<>'{}'::jsonb then v_total else null end,
        copied_from_id=coalesce(copied_from_id,p_copied_from_id),
        copied_at=case
          when copied_at is not null then copied_at
          when p_copied_from_id is not null then now()
          else null
        end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case when p_finalize then 'completed' else 'in_progress' end,
      updated_at=now()
  where assessment_event_id=p_event_id
    and form_code='health'
    and (p_finalize or status<>'completed');

  update public.assessment_events
  set status=case
      when p_finalize and not exists(
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id=p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then 'forms_completed'
      when status='pending' then 'in_progress'
      else status
    end,
    started_at=coalesce(started_at,now()),
    forms_completed_at=case
      when p_finalize and not exists(
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

revoke all on function public.save_assessment_health(uuid,jsonb,jsonb,jsonb,jsonb,boolean,uuid) from public, anon;
grant execute on function public.save_assessment_health(uuid,jsonb,jsonb,jsonb,jsonb,boolean,uuid) to authenticated;
