-- Individual care plans PHASE 1 / test, 2026-10-08
-- This stores INSTITUTION-OWN individual care plans, separate from care_plans (A-unit plans).
-- Prerequisite: private.can_manage_cases() and private.can_edit_assessment_case(uuid) from assessment module.
-- Apply only after confirming the destination project's assessment baseline is current.

begin;

create table if not exists public.individual_care_plans (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.care_cases(id),
  assessment_event_id uuid not null references public.assessment_events(id),
  assessment_date date not null,
  plan_type text not null check (plan_type in ('opening','periodic','change')),
  plan_date date not null default current_date,
  responsible_staff_id uuid references public.staff_users(id),
  assessment_snapshot jsonb not null default '{}'::jsonb,
  plan_content jsonb not null default '{"problems":[],"caregiver":{},"notes":""}'::jsonb,
  status text not null default 'draft' check (status in ('draft','completed')),
  completed_at timestamptz,
  completed_by_staff_id uuid references public.staff_users(id),
  created_by uuid not null,
  updated_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint individual_care_plans_one_per_assessment unique (assessment_event_id),
  constraint individual_care_plans_complete_time check (
    (status='draft' and completed_at is null) or
    (status='completed' and completed_at is not null)
  )
);
create index if not exists individual_care_plans_case_date_idx
  on public.individual_care_plans(case_id,plan_date desc,created_at desc);
create index if not exists individual_care_plans_status_idx
  on public.individual_care_plans(status);

CREATE OR REPLACE FUNCTION private.prepare_individual_care_plan()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events%rowtype;
  v_summary public.assessment_event_summaries%rowtype;
  v_problem jsonb;
  v_goal jsonb;
  v_measure jsonb;
  v_staff_id uuid;
  v_case_supervisor uuid;
begin
  if auth.uid() is null or not private.can_edit_assessment_case(new.case_id) then
    raise exception 'CARE_PLAN_ACCESS_DENIED';
  end if;

  select * into v_event from public.assessment_events
    where id=new.assessment_event_id and case_id=new.case_id and status='completed';
  if not found then
    raise exception 'CARE_PLAN_COMPLETED_ASSESSMENT_REQUIRED';
  end if;

  select supervisor_id into v_case_supervisor from public.care_cases where id=new.case_id;
  select id into v_staff_id from public.staff_users
    where lower(email)=lower(coalesce((select auth.jwt())->>'email',''))
      and is_active=true
      and role in ('supervisor','business_manager','organization_manager','admin')
    limit 1;
  if v_staff_id is null then raise exception 'CARE_PLAN_STAFF_NOT_FOUND'; end if;

  if tg_op='INSERT' then
    new.created_by := auth.uid();
    new.completed_at := null;
    new.completed_by_staff_id := null;
  else
    if old.status='completed' then
      raise exception 'CARE_PLAN_COMPLETED_IMMUTABLE';
    end if;
    if new.case_id<>old.case_id or new.assessment_event_id<>old.assessment_event_id then
      raise exception 'CARE_PLAN_SOURCE_IMMUTABLE';
    end if;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;

  new.assessment_date := v_event.planned_date;
  new.plan_type := case
    when v_event.assessment_type='opening' then 'opening'
    when v_event.assessment_type='periodic' then 'periodic'
    else 'change'
  end;
  new.responsible_staff_id := coalesce(new.responsible_staff_id,v_event.responsible_staff_id,v_case_supervisor);
  select * into v_summary from public.assessment_event_summaries
    where assessment_event_id=v_event.id and completed_at is not null
    order by completed_at desc limit 1;
  new.assessment_snapshot := jsonb_build_object(
    'assessment_event_id',v_event.id,
    'assessment_date',v_event.planned_date,
    'assessment_type',v_event.assessment_type,
    'key_findings',coalesce(v_summary.key_findings,''),
    'care_recommendations',coalesce(v_summary.care_recommendations,'')
  );
  if new.plan_content is null or jsonb_typeof(new.plan_content)<>'object'
     or jsonb_typeof(new.plan_content->'problems')<>'array' then
    raise exception 'CARE_PLAN_INVALID_CONTENT';
  end if;

  if new.status='completed' then
    if jsonb_array_length(new.plan_content->'problems')=0 then
      raise exception 'CARE_PLAN_PROBLEM_REQUIRED';
    end if;
    for v_problem in select value from jsonb_array_elements(new.plan_content->'problems') loop
      if nullif(btrim(coalesce(v_problem->>'category','')),'') is null
         or nullif(btrim(coalesce(v_problem->>'title','')),'') is null
         or nullif(btrim(coalesce(v_problem->>'rationale','')),'') is null
         or jsonb_typeof(v_problem->'goals')<>'array'
         or jsonb_array_length(v_problem->'goals')=0 then
         raise exception 'CARE_PLAN_PROBLEM_INCOMPLETE';
      end if;
      for v_goal in select value from jsonb_array_elements(v_problem->'goals') loop
        if nullif(btrim(coalesce(v_goal->>'title','')),'') is null
           or nullif(btrim(coalesce(v_goal->>'criteria','')),'') is null
           or jsonb_typeof(v_goal->'measures')<>'array'
           or jsonb_array_length(v_goal->'measures')=0 then
          raise exception 'CARE_PLAN_GOAL_INCOMPLETE';
        end if;
        for v_measure in select value from jsonb_array_elements(v_goal->'measures') loop
          if nullif(btrim(coalesce(v_measure->>'text','')),'') is null
            or nullif(btrim(coalesce(v_measure->>'executor','')),'') is null then
            raise exception 'CARE_PLAN_MEASURE_INCOMPLETE';
          end if;
        end loop;
      end loop;
    end loop;
    new.completed_at := now();
    new.completed_by_staff_id := v_staff_id;
  else
    new.completed_at := null;
    new.completed_by_staff_id := null;
  end if;
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end $function$
;

drop trigger if exists individual_care_plan_prepare on public.individual_care_plans;
create trigger individual_care_plan_prepare
before insert or update on public.individual_care_plans
for each row execute function private.prepare_individual_care_plan();

alter table public.individual_care_plans enable row level security;

drop policy if exists individual_care_plans_read on public.individual_care_plans;
create policy individual_care_plans_read on public.individual_care_plans
  for select to authenticated using (private.can_manage_cases());

drop policy if exists individual_care_plans_insert on public.individual_care_plans;
create policy individual_care_plans_insert on public.individual_care_plans
  for insert to authenticated with check (
    created_by=(select auth.uid()) and private.can_edit_assessment_case(case_id));

drop policy if exists individual_care_plans_update on public.individual_care_plans;
create policy individual_care_plans_update on public.individual_care_plans
  for update to authenticated
  using (status='draft' and private.can_edit_assessment_case(case_id))
  with check (private.can_edit_assessment_case(case_id));

revoke all on public.individual_care_plans from public,anon,authenticated;
grant select,insert,update on public.individual_care_plans to authenticated;
grant all on public.individual_care_plans to service_role;
commit;
