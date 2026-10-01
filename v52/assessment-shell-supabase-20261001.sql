
-- V5.2 評估管理：評估事件外殼
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 說明：建立正式評估事件與本次選用評估工具資料表；ADL 等量表內容另於後續階段建立。

begin;

create table if not exists public.assessment_events (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.care_cases(id) on delete cascade,
  assessment_type text not null
    check (assessment_type in ('opening','periodic','condition_change','specific_problem')),
  planned_date date not null,
  reason_code text,
  reason_note text,
  combined_with_home_visit boolean not null default false,
  responsible_staff_id uuid references public.staff_users(id) on delete set null,
  status text not null default 'pending'
    check (status in ('pending','in_progress','forms_completed','completed','voided')),
  started_at timestamptz,
  forms_completed_at timestamptz,
  completed_at timestamptz,
  voided_at timestamptz,
  void_reason text,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_events_case_id_idx
  on public.assessment_events(case_id);
create index if not exists assessment_events_planned_date_idx
  on public.assessment_events(planned_date);
create index if not exists assessment_events_status_idx
  on public.assessment_events(status);
create index if not exists assessment_events_responsible_staff_id_idx
  on public.assessment_events(responsible_staff_id);

create table if not exists public.assessment_event_forms (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  form_code text not null,
  form_name text not null,
  sort_order integer not null default 0,
  is_required boolean not null default false,
  status text not null default 'pending'
    check (status in ('pending','in_progress','completed','unable','not_applicable')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (assessment_event_id, form_code)
);

create index if not exists assessment_event_forms_event_id_idx
  on public.assessment_event_forms(assessment_event_id);

alter table public.assessment_events enable row level security;
alter table public.assessment_event_forms enable row level security;

drop policy if exists assessment_events_read on public.assessment_events;
create policy assessment_events_read
on public.assessment_events
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_events_insert on public.assessment_events;
create policy assessment_events_insert
on public.assessment_events
for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1
    from public.care_cases c
    where c.id = assessment_events.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_events_update on public.assessment_events;
create policy assessment_events_update
on public.assessment_events
for update
to authenticated
using (
  exists (
    select 1
    from public.care_cases c
    where c.id = assessment_events.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1
    from public.care_cases c
    where c.id = assessment_events.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_forms_read on public.assessment_event_forms;
create policy assessment_event_forms_read
on public.assessment_event_forms
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_event_forms_insert on public.assessment_event_forms;
create policy assessment_event_forms_insert
on public.assessment_event_forms
for insert
to authenticated
with check (
  exists (
    select 1
    from public.assessment_events ae
    join public.care_cases c on c.id = ae.case_id
    where ae.id = assessment_event_forms.assessment_event_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_forms_update on public.assessment_event_forms;
create policy assessment_event_forms_update
on public.assessment_event_forms
for update
to authenticated
using (
  exists (
    select 1
    from public.assessment_events ae
    join public.care_cases c on c.id = ae.case_id
    where ae.id = assessment_event_forms.assessment_event_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1
    from public.assessment_events ae
    join public.care_cases c on c.id = ae.case_id
    where ae.id = assessment_event_forms.assessment_event_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_forms_delete on public.assessment_event_forms;
create policy assessment_event_forms_delete
on public.assessment_event_forms
for delete
to authenticated
using (
  exists (
    select 1
    from public.assessment_events ae
    join public.care_cases c on c.id = ae.case_id
    where ae.id = assessment_event_forms.assessment_event_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_events from public, anon, authenticated;
revoke all on public.assessment_event_forms from public, anon, authenticated;

grant select, insert, update on public.assessment_events to authenticated;
grant select, insert, update, delete on public.assessment_event_forms to authenticated;

grant all on public.assessment_events to service_role;
grant all on public.assessment_event_forms to service_role;

commit;
