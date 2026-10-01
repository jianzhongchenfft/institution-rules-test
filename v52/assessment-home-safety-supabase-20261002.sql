-- V5.2 評估管理：居家環境安全評估
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-02
-- 內容：21項居家安全評估、前次帶入、修改歷程與交易式儲存 RPC

create table if not exists public.assessment_home_safety_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  home_profile jsonb not null default '{}'::jsonb,
  answers jsonb not null default '{}'::jsonb,
  notes jsonb not null default '{}'::jsonb,
  summary jsonb not null default '{}'::jsonb,
  copied_from_id uuid references public.assessment_home_safety_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_home_safety_records_case_id_idx
  on public.assessment_home_safety_records(case_id);
create index if not exists assessment_home_safety_records_event_id_idx
  on public.assessment_home_safety_records(assessment_event_id);
create index if not exists assessment_home_safety_records_confirmed_at_idx
  on public.assessment_home_safety_records(confirmed_at);
create index if not exists assessment_home_safety_records_copied_from_id_idx
  on public.assessment_home_safety_records(copied_from_id);

create table if not exists public.assessment_home_safety_history (
  id uuid primary key default gen_random_uuid(),
  home_safety_record_id uuid not null references public.assessment_home_safety_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_home_safety_history_record_idx
  on public.assessment_home_safety_history(home_safety_record_id, changed_at);
create index if not exists assessment_home_safety_history_case_idx
  on public.assessment_home_safety_history(case_id, changed_at);
create index if not exists assessment_home_safety_history_event_idx
  on public.assessment_home_safety_history(assessment_event_id);

alter table public.assessment_home_safety_records enable row level security;
alter table public.assessment_home_safety_history enable row level security;

drop policy if exists assessment_home_safety_read on public.assessment_home_safety_records;
create policy assessment_home_safety_read
on public.assessment_home_safety_records
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_home_safety_insert on public.assessment_home_safety_records;
create policy assessment_home_safety_insert
on public.assessment_home_safety_records
for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_home_safety_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_home_safety_update on public.assessment_home_safety_records;
create policy assessment_home_safety_update
on public.assessment_home_safety_records
for update
to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_home_safety_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_home_safety_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_home_safety_history_read on public.assessment_home_safety_history;
create policy assessment_home_safety_history_read
on public.assessment_home_safety_history
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_home_safety_history_insert on public.assessment_home_safety_history;
create policy assessment_home_safety_history_insert
on public.assessment_home_safety_history
for insert
to authenticated
with check (
  changed_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_home_safety_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_home_safety_records from public, anon, authenticated;
revoke all on public.assessment_home_safety_history from public, anon, authenticated;
grant select, insert, update on public.assessment_home_safety_records to authenticated;
grant select, insert on public.assessment_home_safety_history to authenticated;
grant all on public.assessment_home_safety_records to service_role;
grant all on public.assessment_home_safety_history to service_role;

create or replace function public.save_assessment_home_safety(
  p_event_id uuid,
  p_home_profile jsonb,
  p_answers jsonb,
  p_notes jsonb,
  p_summary jsonb,
  p_finalize boolean default false,
  p_copied_from_id uuid default null
)
returns public.assessment_home_safety_records
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_home_safety_records;
  v_old public.assessment_home_safety_records;
  v_key text;
  v_status text;
  v_required text[] := array[
    'entrance_clear','floor_level','floor_nonslip','walkway_clear','lighting','furniture_safe',
    'bath_floor_nonslip','bath_seat','bath_grab','toilet_transfer','bath_threshold',
    'bed_transfer','night_lighting','night_toilet_route',
    'stairs_lighting','stairs_handrail','stairs_nonslip',
    'kitchen_reach','kitchen_floor_work',
    'emergency_contact','escape_route'
  ];
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id = p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id = v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id = p_event_id and f.form_code = 'home_safety'
  ) then raise exception 'HOME_SAFETY_FORM_NOT_SELECTED'; end if;

  p_home_profile := coalesce(p_home_profile, '{}'::jsonb);
  p_answers := coalesce(p_answers, '{}'::jsonb);
  p_notes := coalesce(p_notes, '{}'::jsonb);
  p_summary := coalesce(p_summary, '{}'::jsonb);

  foreach v_key in array v_required loop
    if p_answers ? v_key then
      v_status := p_answers ->> v_key;
      if v_status not in ('safe','needs_improvement','not_applicable') then
        raise exception 'INVALID_HOME_SAFETY_STATUS:%', v_key;
      end if;
    elsif p_finalize then
      raise exception 'HOME_SAFETY_INCOMPLETE:%', v_key;
    end if;
  end loop;

  select * into v_old
  from public.assessment_home_safety_records
  where assessment_event_id = p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_home_safety_records(
      assessment_event_id, case_id, home_profile, answers, notes, summary,
      copied_from_id, copied_at, confirmed_at, created_by, updated_by
    ) values (
      p_event_id, v_event.case_id, p_home_profile, p_answers, p_notes, p_summary,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()), (select auth.uid())
    ) returning * into v_record;
  else
    if v_old.home_profile is distinct from p_home_profile then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (v_old.id, p_event_id, v_event.case_id, 'home_profile', v_old.home_profile, p_home_profile, (select auth.uid()));
    end if;

    if v_old.answers is distinct from p_answers then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (v_old.id, p_event_id, v_event.case_id, 'answers', v_old.answers, p_answers, (select auth.uid()));
    end if;

    if v_old.notes is distinct from p_notes then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (v_old.id, p_event_id, v_event.case_id, 'notes', v_old.notes, p_notes, (select auth.uid()));
    end if;

    if v_old.summary is distinct from p_summary then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (v_old.id, p_event_id, v_event.case_id, 'summary', v_old.summary, p_summary, (select auth.uid()));
    end if;

    update public.assessment_home_safety_records
    set
      home_profile = p_home_profile,
      answers = p_answers,
      notes = p_notes,
      summary = p_summary,
      copied_from_id = coalesce(p_copied_from_id, copied_from_id),
      copied_at = case
        when p_copied_from_id is not null and p_copied_from_id is distinct from copied_from_id then now()
        else copied_at
      end,
      confirmed_at = case when p_finalize then now() else confirmed_at end,
      updated_by = (select auth.uid()),
      updated_at = now()
    where id = v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status = case when p_finalize then 'completed' else 'in_progress' end,
      updated_at = now()
  where assessment_event_id = p_event_id
    and form_code = 'home_safety'
    and (p_finalize or status <> 'completed');

  update public.assessment_events
  set
    status = case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id = p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then 'forms_completed'
      when status = 'pending' then 'in_progress'
      else status
    end,
    started_at = coalesce(started_at, now()),
    forms_completed_at = case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id = p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then coalesce(forms_completed_at, now())
      else forms_completed_at
    end,
    updated_by = (select auth.uid()),
    updated_at = now()
  where id = p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_home_safety(uuid,jsonb,jsonb,jsonb,jsonb,boolean,uuid) from public, anon;
grant execute on function public.save_assessment_home_safety(uuid,jsonb,jsonb,jsonb,jsonb,boolean,uuid) to authenticated;
