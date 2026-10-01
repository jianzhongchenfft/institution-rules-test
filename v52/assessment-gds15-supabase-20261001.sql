-- V5.2 評估管理：GDS-15 公版
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 題目與計分邏輯採桃園市政府衛生局老人心理健康評估表(GDS-15)／衛福部公版。
-- 最近一週、15題、是／否。
-- 第1、5、7、11、13題答「否」計1分；其餘10題答「是」計1分；總分0–15。
-- 支援正常評估、無法評估、不適用；後兩者需填原因。

begin;

create table if not exists public.assessment_gds15_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  answers jsonb not null default '{}'::jsonb,
  total_score integer check (total_score between 0 and 15),
  completion_mode text not null default 'completed'
    check (completion_mode in ('completed','unable','not_applicable')),
  exception_reason text,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    completion_mode='completed'
    or (exception_reason is not null and btrim(exception_reason)<>'')
  )
);

create index if not exists assessment_gds15_records_case_id_idx on public.assessment_gds15_records(case_id);
create index if not exists assessment_gds15_records_event_id_idx on public.assessment_gds15_records(assessment_event_id);
create index if not exists assessment_gds15_records_confirmed_at_idx on public.assessment_gds15_records(confirmed_at);

create table if not exists public.assessment_gds15_history (
  id uuid primary key default gen_random_uuid(),
  gds15_record_id uuid not null references public.assessment_gds15_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_gds15_history_record_idx on public.assessment_gds15_history(gds15_record_id, changed_at);
create index if not exists assessment_gds15_history_case_idx on public.assessment_gds15_history(case_id, changed_at);
create index if not exists assessment_gds15_history_event_id_idx on public.assessment_gds15_history(assessment_event_id);

alter table public.assessment_gds15_records enable row level security;
alter table public.assessment_gds15_history enable row level security;

drop policy if exists assessment_gds15_read on public.assessment_gds15_records;
create policy assessment_gds15_read on public.assessment_gds15_records for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_gds15_insert on public.assessment_gds15_records;
create policy assessment_gds15_insert on public.assessment_gds15_records for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_gds15_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_gds15_update on public.assessment_gds15_records;
create policy assessment_gds15_update on public.assessment_gds15_records for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_gds15_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_gds15_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_gds15_history_read on public.assessment_gds15_history;
create policy assessment_gds15_history_read on public.assessment_gds15_history for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_gds15_history_insert on public.assessment_gds15_history;
create policy assessment_gds15_history_insert on public.assessment_gds15_history for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_gds15_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_gds15_records from public, anon, authenticated;
revoke all on public.assessment_gds15_history from public, anon, authenticated;
grant select, insert, update on public.assessment_gds15_records to authenticated;
grant select, insert on public.assessment_gds15_history to authenticated;
grant all on public.assessment_gds15_records to service_role;
grant all on public.assessment_gds15_history to service_role;

commit;

create or replace function public.save_assessment_gds15(
  p_event_id uuid,
  p_answers jsonb,
  p_finalize boolean default false,
  p_completion_mode text default 'completed',
  p_exception_reason text default null
)
returns public.assessment_gds15_records
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_gds15_records;
  v_old public.assessment_gds15_records;
  v_key text;
  v_keys text[]:=array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10','q11','q12','q13','q14','q15'];
  v_reverse text[]:=array['q1','q5','q7','q11','q13'];
  v_value text;
  v_total integer:=0;
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
    where f.assessment_event_id=p_event_id and f.form_code='gds15'
  ) then raise exception 'GDS15_FORM_NOT_SELECTED'; end if;

  p_answers:=coalesce(p_answers,'{}'::jsonb);
  p_completion_mode:=coalesce(p_completion_mode,'completed');
  p_exception_reason:=nullif(btrim(p_exception_reason),'');

  if p_completion_mode not in ('completed','unable','not_applicable') then
    raise exception 'INVALID_GDS15_COMPLETION_MODE';
  end if;

  if p_completion_mode<>'completed' and p_exception_reason is null then
    raise exception 'GDS15_EXCEPTION_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_value:=p_answers->>v_key;

    if v_value is not null and v_value not in ('yes','no') then
      raise exception 'INVALID_GDS15_ANSWER:%',v_key;
    end if;

    if p_finalize and p_completion_mode='completed' and v_value is null then
      raise exception 'GDS15_INCOMPLETE:%',v_key;
    end if;

    if p_completion_mode='completed' and v_value is not null then
      if v_key=any(v_reverse) then
        if v_value='no' then v_total:=v_total+1; end if;
      else
        if v_value='yes' then v_total:=v_total+1; end if;
      end if;
    end if;
  end loop;

  select * into v_old
  from public.assessment_gds15_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_gds15_records(
      assessment_event_id,case_id,answers,total_score,completion_mode,exception_reason,
      confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_answers,
      case when p_completion_mode='completed' and p_answers<>'{}'::jsonb then v_total else null end,
      p_completion_mode,p_exception_reason,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb)||p_answers) as t(key)
    loop
      if (v_old.answers->v_key) is distinct from (p_answers->v_key) then
        insert into public.assessment_gds15_history(
          gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'answers.'||v_key,
          v_old.answers->v_key,p_answers->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.completion_mode is distinct from p_completion_mode then
      insert into public.assessment_gds15_history(
        gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'completion_mode',
        to_jsonb(v_old.completion_mode),to_jsonb(p_completion_mode),(select auth.uid())
      );
    end if;

    if v_old.exception_reason is distinct from p_exception_reason then
      insert into public.assessment_gds15_history(
        gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'exception_reason',
        to_jsonb(v_old.exception_reason),to_jsonb(p_exception_reason),(select auth.uid())
      );
    end if;

    update public.assessment_gds15_records
    set answers=p_answers,
        total_score=case when p_completion_mode='completed' and p_answers<>'{}'::jsonb then v_total else null end,
        completion_mode=p_completion_mode,
        exception_reason=p_exception_reason,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case
      when p_finalize and p_completion_mode='unable' then 'unable'
      when p_finalize and p_completion_mode='not_applicable' then 'not_applicable'
      when p_finalize then 'completed'
      else 'in_progress'
    end,
    updated_at=now()
  where assessment_event_id=p_event_id and form_code='gds15';

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

revoke all on function public.save_assessment_gds15(uuid,jsonb,boolean,text,text) from public, anon;
grant execute on function public.save_assessment_gds15(uuid,jsonb,boolean,text,text) to authenticated;
