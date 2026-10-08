begin;
alter table public.individual_care_plans
  add column root_plan_id uuid references public.individual_care_plans(id),
  add column previous_version_id uuid references public.individual_care_plans(id),
  add column revision_type text check (revision_type in ('correction','revision')),
  add column revision_reason text,
  add column version_no integer not null default 1;
alter table public.individual_care_plans
  drop constraint individual_care_plans_one_per_assessment;
create unique index individual_care_plan_root_per_assessment
  on public.individual_care_plans(assessment_event_id) where root_plan_id is null;
create unique index individual_care_plan_version_by_assessment
  on public.individual_care_plans(assessment_event_id,version_no);
create unique index individual_care_plan_one_open_revision
  on public.individual_care_plans(assessment_event_id) where root_plan_id is not null and status='draft';
alter table public.individual_care_plans
  add constraint individual_care_plan_version_kind_check check (
    (root_plan_id is null and previous_version_id is null and revision_type is null and version_no=1)
    or (root_plan_id is not null and previous_version_id is not null and revision_type in ('correction','revision') and version_no>=2)
  );
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
  v_parent public.individual_care_plans%rowtype;
  v_prev public.individual_care_plans%rowtype;
  v_current_id uuid;
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
    if new.root_plan_id is null then
      if new.previous_version_id is not null or new.revision_type is not null then
        raise exception 'CARE_PLAN_ROOT_VERSION_INVALID';
      end if;
      new.version_no := 1;
    else
      select * into v_parent from public.individual_care_plans
        where id=new.root_plan_id and root_plan_id is null and status='completed' for update;
      if not found then raise exception 'CARE_PLAN_ROOT_NOT_COMPLETED'; end if;
      if v_parent.case_id is distinct from new.case_id
        or v_parent.assessment_event_id is distinct from new.assessment_event_id then
        raise exception 'CARE_PLAN_REVISION_SOURCE_MISMATCH';
      end if;
      if new.revision_type not in ('correction','revision') or new.previous_version_id is null then
        raise exception 'CARE_PLAN_REVISION_TYPE_REQUIRED';
      end if;
      select * into v_prev from public.individual_care_plans
        where id=new.previous_version_id and status='completed'
        and assessment_event_id=new.assessment_event_id
        and (id=new.root_plan_id or root_plan_id=new.root_plan_id);
      if not found then raise exception 'CARE_PLAN_PREVIOUS_VERSION_INVALID'; end if;
      select id into v_current_id from public.individual_care_plans
        where assessment_event_id=new.assessment_event_id and status='completed'
        order by version_no desc limit 1;
      if v_current_id is distinct from v_prev.id then
        raise exception 'CARE_PLAN_REVISION_OUTDATED';
      end if;
      new.version_no := v_prev.version_no + 1;
      if nullif(btrim(coalesce(new.revision_reason,'')),'') is null then
        raise exception 'CARE_PLAN_REVISION_REASON_REQUIRED';
      end if;
    end if;
    new.created_by := auth.uid();
    new.completed_at := null;
    new.completed_by_staff_id := null;
  else
    if old.status='completed' then
      raise exception 'CARE_PLAN_COMPLETED_IMMUTABLE';
    end if;
    if new.case_id<>old.case_id or new.assessment_event_id<>old.assessment_event_id
      or new.root_plan_id is distinct from old.root_plan_id
      or new.previous_version_id is distinct from old.previous_version_id
      or new.revision_type is distinct from old.revision_type
      or new.version_no is distinct from old.version_no then
      raise exception 'CARE_PLAN_SOURCE_IMMUTABLE';
    end if;
    if new.root_plan_id is not null then
      if nullif(btrim(coalesce(new.revision_reason,'')),'') is null then
        raise exception 'CARE_PLAN_REVISION_REASON_REQUIRED';
      end if;
      select * into v_prev from public.individual_care_plans
        where id=new.previous_version_id and status='completed';
      if not found then raise exception 'CARE_PLAN_PREVIOUS_VERSION_INVALID'; end if;
      select id into v_current_id from public.individual_care_plans
        where assessment_event_id=new.assessment_event_id and status='completed'
        order by version_no desc limit 1;
      if v_current_id is distinct from v_prev.id then raise exception 'CARE_PLAN_REVISION_OUTDATED'; end if;
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
    if new.revision_type='correction' and new.root_plan_id is not null then
      -- A correction may fix wording only. Changes of goals, services, dates, or structural IDs are revisions.
      if new.plan_date is distinct from v_prev.plan_date
        or jsonb_path_query_array(new.plan_content,'$.problems[*].id') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].id')
        or jsonb_path_query_array(new.plan_content,'$.problems[*].category') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].category')
        or jsonb_path_query_array(new.plan_content,'$.problems[*].goals[*].id') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].goals[*].id')
        or jsonb_path_query_array(new.plan_content,'$.problems[*].goals[*].review_months') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].goals[*].review_months')
        or jsonb_path_query_array(new.plan_content,'$.problems[*].goals[*].review_date') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].goals[*].review_date')
        or jsonb_path_query_array(new.plan_content,'$.problems[*].goals[*].measures[*].id') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].goals[*].measures[*].id')
        or jsonb_path_query_array(new.plan_content,'$.problems[*].goals[*].measures[*].service_code') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].goals[*].measures[*].service_code')
        or jsonb_path_query_array(new.plan_content,'$.problems[*].goals[*].measures[*].measure_type') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].goals[*].measures[*].measure_type')
        or jsonb_path_query_array(new.plan_content,'$.problems[*].goals[*].measures[*].proposed_service') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].goals[*].measures[*].proposed_service')
        or jsonb_path_query_array(new.plan_content,'$.problems[*].goals[*].measures[*].executor') is distinct from jsonb_path_query_array(v_prev.plan_content,'$.problems[*].goals[*].measures[*].executor')
      then raise exception 'CARE_PLAN_CORRECTION_STRUCTURE_CHANGED'; end if;
    end if;
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
        -- 每項目標的相對評值月份：獨立保存月份及依計畫日期算出的日期。
        if coalesce(v_goal->>'review_months','') !~ '^[1-9][0-9]{0,2}$' then
          raise exception 'CARE_PLAN_REVIEW_MONTHS_INVALID';
        end if;
        if (v_goal->>'review_months')::integer > 120 then
          raise exception 'CARE_PLAN_REVIEW_MONTHS_INVALID';
        end if;
        if coalesce(v_goal->>'review_date','') <>
          ((new.plan_date + make_interval(months => (v_goal->>'review_months')::integer))::date)::text then
          raise exception 'CARE_PLAN_REVIEW_DATE_MISMATCH';
        end if;
        for v_measure in select value from jsonb_array_elements(v_goal->'measures') loop
          if nullif(btrim(coalesce(v_measure->>'text','')),'') is null
            or nullif(btrim(coalesce(v_measure->>'executor','')),'') is null then
            raise exception 'CARE_PLAN_MEASURE_INCOMPLETE';
          end if;
          -- 核定服務執行須連結個案目前有效的 BA／GA 項目；督導可跨個案編輯。
          if coalesce(v_measure->>'measure_type','service') = 'service' then
            if nullif(btrim(coalesce(v_measure->>'service_code','')),'') is null
              or not exists (
                select 1 from public.case_approved_services s
                where s.case_id = new.case_id
                  and s.is_current = true
                  and s.service_group in ('B','G')
                  and s.service_code ~ '^(BA|GA)[0-9]'
                  and s.service_code = v_measure->>'service_code'
                  and (s.approved_quantity is null or s.approved_quantity > 0)
                  and (s.valid_from is null or s.valid_from <= current_date)
                  and (s.valid_to is null or s.valid_to >= current_date)
              ) then
              raise exception 'CARE_PLAN_SERVICE_NOT_APPROVED: %', coalesce(v_measure->>'service_code','未選擇');
            end if;
          elsif v_measure->>'measure_type' = 'non_service' then
            if nullif(btrim(coalesce(v_measure->>'service_code','')),'') is not null then
              raise exception 'CARE_PLAN_NON_SERVICE_CANNOT_LINK_CODE';
            end if;
          elsif v_measure->>'measure_type' = 'pending' then
            -- 建議事項可寫入正式計畫，但不可當作核定可執行服務。
            if nullif(btrim(coalesce(v_measure->>'proposed_service','')),'') is null then
              raise exception 'CARE_PLAN_PENDING_DETAIL_REQUIRED';
            end if;
            if nullif(btrim(coalesce(v_measure->>'service_code','')),'') is not null then
              raise exception 'CARE_PLAN_PENDING_CANNOT_LINK_CODE';
            end if;
          else
            raise exception 'CARE_PLAN_MEASURE_TYPE_INVALID';
          end if;
        end loop;
      end loop;
    end loop;
    new.plan_content := jsonb_set(
      new.plan_content, '{approved_services_snapshot}',
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',s.id,
          'code',s.service_code,
          'name',s.service_name,
          'group',s.service_group,
          'approved_quantity',s.approved_quantity,
          'care_plan_id',s.care_plan_id,
          'valid_from',s.valid_from,
          'valid_to',s.valid_to
        ) order by s.service_code)
        from public.case_approved_services s
        where s.case_id=new.case_id and s.is_current=true
          and s.service_group in ('B','G')
          and s.service_code ~ '^(BA|GA)[0-9]'
          and (s.approved_quantity is null or s.approved_quantity > 0)
          and (s.valid_from is null or s.valid_from <= current_date)
          and (s.valid_to is null or s.valid_to >= current_date)
      ), '[]'::jsonb), true
    );
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

create table public.individual_care_plan_reviews(
 id uuid primary key default gen_random_uuid(),
 plan_id uuid not null references public.individual_care_plans(id),
 case_id uuid not null references public.care_cases(id),
 problem_id text not null,
 goal_id text not null,
 batch_id uuid not null,
 review_type text not null check (review_type in ('periodic','interim')),
 review_date date not null,
 result text not null check (result in ('achieved','partial','unmet','unable')),
 comments text not null default '',
 disposition text not null check (disposition in ('maintain','adjust','end')),
 created_at timestamptz not null default now(),
 reviewed_by_staff_id uuid references public.staff_users(id),
 created_by uuid not null,
 constraint individual_care_plan_reviews_reason_check check (
   result not in ('partial','unmet','unable') or nullif(btrim(comments),'') is not null
 )
);
create index individual_care_plan_reviews_case_date on public.individual_care_plan_reviews(case_id,review_date desc,created_at desc);
create index individual_care_plan_reviews_plan_goal on public.individual_care_plan_reviews(plan_id,goal_id,created_at desc);
create unique index individual_care_plan_reviews_one_goal_per_batch on public.individual_care_plan_reviews(batch_id,goal_id);
create function private.validate_individual_care_plan_review()
returns trigger language plpgsql security invoker set search_path=''
as $$
declare
  v_plan public.individual_care_plans%rowtype;
  v_staff_id uuid;
begin
  if (select auth.uid()) is null or not private.can_edit_assessment_case(new.case_id) then
    raise exception 'CARE_PLAN_REVIEW_ACCESS_DENIED';
  end if;
  select * into v_plan from public.individual_care_plans
    where id=new.plan_id and status='completed' and case_id=new.case_id;
  if not found then raise exception 'CARE_PLAN_REVIEW_PLAN_INVALID'; end if;
  if not exists (
    select 1 from jsonb_array_elements(v_plan.plan_content->'problems') p
    cross join lateral jsonb_array_elements(p->'goals') g
    where p->>'id'=new.problem_id and g->>'id'=new.goal_id
  ) then raise exception 'CARE_PLAN_REVIEW_GOAL_INVALID'; end if;
  if new.review_type='periodic' and new.review_date < v_plan.plan_date then
    raise exception 'CARE_PLAN_REVIEW_DATE_INVALID'; end if;
  select s.id into v_staff_id from public.staff_users s
    where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
    and s.is_active=true and s.role in ('supervisor','business_manager','organization_manager','admin')
    limit 1;
  if v_staff_id is null then raise exception 'CARE_PLAN_REVIEW_STAFF_NOT_FOUND'; end if;
  new.created_by := auth.uid();
  new.reviewed_by_staff_id := v_staff_id;
  new.created_at := now();
  return new;
end $$;
create trigger individual_care_plan_review_validate
before insert on public.individual_care_plan_reviews for each row
execute function private.validate_individual_care_plan_review();
alter table public.individual_care_plan_reviews enable row level security;
create policy individual_care_plan_reviews_read
  on public.individual_care_plan_reviews for select to authenticated
  using (private.can_manage_cases());
create policy individual_care_plan_reviews_insert
  on public.individual_care_plan_reviews for insert to authenticated
  with check (created_by=(select auth.uid()) and private.can_edit_assessment_case(case_id));
revoke all on public.individual_care_plan_reviews from public,anon,authenticated;
grant select,insert on public.individual_care_plan_reviews to authenticated;
grant all on public.individual_care_plan_reviews to service_role;
commit;