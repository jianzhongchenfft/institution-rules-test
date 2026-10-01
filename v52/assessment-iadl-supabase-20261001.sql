-- V5.2 評估管理：Lawton IADL
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 說明：建立 IADL 結構化紀錄、修改歷程、RLS 與儲存 RPC。
-- 前次紀錄的選擇由前端依本次評估日期動態判斷，不以建立順序判斷。

begin;

create table if not exists public.assessment_iadl_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  answers jsonb not null default '{}'::jsonb,
  notes jsonb not null default '{}'::jsonb,
  total_score integer check (total_score between 0 and 16),
  copied_from_id uuid references public.assessment_iadl_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_iadl_records_case_id_idx
  on public.assessment_iadl_records(case_id);
create index if not exists assessment_iadl_records_event_id_idx
  on public.assessment_iadl_records(assessment_event_id);
create index if not exists assessment_iadl_records_confirmed_at_idx
  on public.assessment_iadl_records(confirmed_at);
create index if not exists assessment_iadl_records_copied_from_id_idx
  on public.assessment_iadl_records(copied_from_id);

create table if not exists public.assessment_iadl_history (
  id uuid primary key default gen_random_uuid(),
  iadl_record_id uuid not null references public.assessment_iadl_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_iadl_history_record_idx
  on public.assessment_iadl_history(iadl_record_id, changed_at);
create index if not exists assessment_iadl_history_case_idx
  on public.assessment_iadl_history(case_id, changed_at);
create index if not exists assessment_iadl_history_event_id_idx
  on public.assessment_iadl_history(assessment_event_id);

alter table public.assessment_iadl_records enable row level security;
alter table public.assessment_iadl_history enable row level security;

drop policy if exists assessment_iadl_read on public.assessment_iadl_records;
create policy assessment_iadl_read
on public.assessment_iadl_records
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_iadl_insert on public.assessment_iadl_records;
create policy assessment_iadl_insert
on public.assessment_iadl_records
for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_iadl_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_iadl_update on public.assessment_iadl_records;
create policy assessment_iadl_update
on public.assessment_iadl_records
for update
to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_iadl_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_iadl_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_iadl_history_read on public.assessment_iadl_history;
create policy assessment_iadl_history_read
on public.assessment_iadl_history
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_iadl_history_insert on public.assessment_iadl_history;
create policy assessment_iadl_history_insert
on public.assessment_iadl_history
for insert
to authenticated
with check (
  changed_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_iadl_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_iadl_records from public, anon, authenticated;
revoke all on public.assessment_iadl_history from public, anon, authenticated;
grant select, insert, update on public.assessment_iadl_records to authenticated;
grant select, insert on public.assessment_iadl_history to authenticated;
grant all on public.assessment_iadl_records to service_role;
grant all on public.assessment_iadl_history to service_role;

commit;

create or replace function public.save_assessment_iadl(
  p_event_id uuid,
  p_answers jsonb,
  p_notes jsonb,
  p_finalize boolean default false,
  p_copied_from_id uuid default null
)
returns public.assessment_iadl_records
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_iadl_records;
  v_old public.assessment_iadl_records;
  v_total integer := 0;
  v_key text;
  v_required text[] := array[
    'telephone','shopping','meal_prep','housekeeping',
    'laundry','transportation','medication','finances'
  ];
  v_score integer;
begin
  if (select auth.uid()) is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_event
  from public.assessment_events
  where id = p_event_id;

  if v_event.id is null then
    raise exception 'ASSESSMENT_EVENT_NOT_FOUND';
  end if;

  select * into v_case
  from public.care_cases
  where id = v_event.case_id;

  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1
    from public.assessment_event_forms f
    where f.assessment_event_id = p_event_id
      and f.form_code = 'iadl'
  ) then
    raise exception 'IADL_FORM_NOT_SELECTED';
  end if;

  p_answers := coalesce(p_answers, '{}'::jsonb);
  p_notes := coalesce(p_notes, '{}'::jsonb);

  foreach v_key in array v_required loop
    if (p_answers ->> v_key) is not null then
      begin
        v_score := (p_answers ->> v_key)::integer;
      exception when others then
        raise exception 'INVALID_IADL_SCORE:%', v_key;
      end;

      if v_score not in (0,1,2) then
        raise exception 'INVALID_IADL_SCORE:%', v_key;
      end if;

      v_total := v_total + v_score;
    elsif p_finalize then
      raise exception 'IADL_INCOMPLETE:%', v_key;
    end if;
  end loop;

  select * into v_old
  from public.assessment_iadl_records
  where assessment_event_id = p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_iadl_records(
      assessment_event_id, case_id, answers, notes, total_score,
      copied_from_id, copied_at, confirmed_at, created_by, updated_by
    ) values (
      p_event_id, v_event.case_id, p_answers, p_notes,
      case when p_answers <> '{}'::jsonb then v_total else null end,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()), (select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb) || p_answers) as t(key)
    loop
      if (v_old.answers -> v_key) is distinct from (p_answers -> v_key) then
        insert into public.assessment_iadl_history(
          iadl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'answers.'||v_key,
          v_old.answers -> v_key, p_answers -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb) || p_notes) as t(key)
    loop
      if (v_old.notes -> v_key) is distinct from (p_notes -> v_key) then
        insert into public.assessment_iadl_history(
          iadl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'notes.'||v_key,
          v_old.notes -> v_key, p_notes -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    update public.assessment_iadl_records
    set
      answers = p_answers,
      notes = p_notes,
      total_score = case when p_answers <> '{}'::jsonb then v_total else null end,
      copied_from_id = coalesce(copied_from_id, p_copied_from_id),
      copied_at = case
        when copied_at is not null then copied_at
        when p_copied_from_id is not null then now()
        else null
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
    and form_code = 'iadl'
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

revoke all on function public.save_assessment_iadl(uuid,jsonb,jsonb,boolean,uuid) from public, anon;
grant execute on function public.save_assessment_iadl(uuid,jsonb,jsonb,boolean,uuid) to authenticated;
