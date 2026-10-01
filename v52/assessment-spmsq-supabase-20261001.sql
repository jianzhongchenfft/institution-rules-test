-- V5.2 評估管理：SPMSQ
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 依機構現行表單：10題、受訪者回答、正確／錯誤判定、錯誤題數、無法評估原因。

begin;

create table if not exists public.assessment_spmsq_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  responses jsonb not null default '{}'::jsonb,
  judgments jsonb not null default '{}'::jsonb,
  error_count integer check (error_count between 0 and 10),
  is_unable boolean not null default false,
  unable_reason text,
  copied_from_id uuid references public.assessment_spmsq_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((not is_unable) or (unable_reason is not null and btrim(unable_reason) <> ''))
);

create index if not exists assessment_spmsq_records_case_id_idx on public.assessment_spmsq_records(case_id);
create index if not exists assessment_spmsq_records_event_id_idx on public.assessment_spmsq_records(assessment_event_id);
create index if not exists assessment_spmsq_records_confirmed_at_idx on public.assessment_spmsq_records(confirmed_at);
create index if not exists assessment_spmsq_records_copied_from_id_idx on public.assessment_spmsq_records(copied_from_id);

create table if not exists public.assessment_spmsq_history (
  id uuid primary key default gen_random_uuid(),
  spmsq_record_id uuid not null references public.assessment_spmsq_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_spmsq_history_record_idx on public.assessment_spmsq_history(spmsq_record_id, changed_at);
create index if not exists assessment_spmsq_history_case_idx on public.assessment_spmsq_history(case_id, changed_at);
create index if not exists assessment_spmsq_history_event_id_idx on public.assessment_spmsq_history(assessment_event_id);

alter table public.assessment_spmsq_records enable row level security;
alter table public.assessment_spmsq_history enable row level security;

drop policy if exists assessment_spmsq_read on public.assessment_spmsq_records;
create policy assessment_spmsq_read on public.assessment_spmsq_records for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_spmsq_insert on public.assessment_spmsq_records;
create policy assessment_spmsq_insert on public.assessment_spmsq_records for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_spmsq_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_spmsq_update on public.assessment_spmsq_records;
create policy assessment_spmsq_update on public.assessment_spmsq_records for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_spmsq_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_spmsq_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_spmsq_history_read on public.assessment_spmsq_history;
create policy assessment_spmsq_history_read on public.assessment_spmsq_history for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_spmsq_history_insert on public.assessment_spmsq_history;
create policy assessment_spmsq_history_insert on public.assessment_spmsq_history for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_spmsq_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_spmsq_records from public, anon, authenticated;
revoke all on public.assessment_spmsq_history from public, anon, authenticated;
grant select, insert, update on public.assessment_spmsq_records to authenticated;
grant select, insert on public.assessment_spmsq_history to authenticated;
grant all on public.assessment_spmsq_records to service_role;
grant all on public.assessment_spmsq_history to service_role;

commit;

create or replace function public.save_assessment_spmsq(
  p_event_id uuid,
  p_responses jsonb,
  p_judgments jsonb,
  p_finalize boolean default false,
  p_unable boolean default false,
  p_unable_reason text default null,
  p_copied_from_id uuid default null
)
returns public.assessment_spmsq_records
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_spmsq_records;
  v_old public.assessment_spmsq_records;
  v_key text;
  v_keys text[]:=array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10'];
  v_judgment text;
  v_error_count integer:=0;
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
    where f.assessment_event_id=p_event_id and f.form_code='spmsq'
  ) then raise exception 'SPMSQ_FORM_NOT_SELECTED'; end if;

  p_responses:=coalesce(p_responses,'{}'::jsonb);
  p_judgments:=coalesce(p_judgments,'{}'::jsonb);
  p_unable_reason:=nullif(btrim(p_unable_reason),'');

  if p_finalize and p_unable and p_unable_reason is null then
    raise exception 'SPMSQ_UNABLE_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_judgment:=p_judgments->>v_key;
    if v_judgment is not null and v_judgment not in ('correct','wrong') then
      raise exception 'INVALID_SPMSQ_JUDGMENT:%',v_key;
    end if;

    if not p_unable then
      if p_finalize and nullif(btrim(p_responses->>v_key),'') is null then
        raise exception 'SPMSQ_RESPONSE_INCOMPLETE:%',v_key;
      end if;
      if p_finalize and v_judgment is null then
        raise exception 'SPMSQ_JUDGMENT_INCOMPLETE:%',v_key;
      end if;
      if v_judgment='wrong' then v_error_count:=v_error_count+1; end if;
    end if;
  end loop;

  select * into v_old from public.assessment_spmsq_records
  where assessment_event_id=p_event_id for update;

  if v_old.id is null then
    insert into public.assessment_spmsq_records(
      assessment_event_id,case_id,responses,judgments,error_count,is_unable,unable_reason,
      copied_from_id,copied_at,confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_responses,p_judgments,
      case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
      p_unable,p_unable_reason,p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in select key from jsonb_object_keys(coalesce(v_old.responses,'{}'::jsonb)||p_responses) as t(key)
    loop
      if (v_old.responses->v_key) is distinct from (p_responses->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'responses.'||v_key,
          v_old.responses->v_key,p_responses->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in select key from jsonb_object_keys(coalesce(v_old.judgments,'{}'::jsonb)||p_judgments) as t(key)
    loop
      if (v_old.judgments->v_key) is distinct from (p_judgments->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'judgments.'||v_key,
          v_old.judgments->v_key,p_judgments->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.is_unable is distinct from p_unable then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'is_unable',
        to_jsonb(v_old.is_unable),to_jsonb(p_unable),(select auth.uid())
      );
    end if;

    if v_old.unable_reason is distinct from p_unable_reason then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'unable_reason',
        to_jsonb(v_old.unable_reason),to_jsonb(p_unable_reason),(select auth.uid())
      );
    end if;

    update public.assessment_spmsq_records
    set responses=p_responses,
        judgments=p_judgments,
        error_count=case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
        is_unable=p_unable,
        unable_reason=p_unable_reason,
        copied_from_id=coalesce(copied_from_id,p_copied_from_id),
        copied_at=case when copied_at is not null then copied_at when p_copied_from_id is not null then now() else null end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case when p_finalize and p_unable then 'unable' when p_finalize then 'completed' else 'in_progress' end,
      updated_at=now()
  where assessment_event_id=p_event_id and form_code='spmsq';

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

revoke all on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) from public, anon;
grant execute on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) to authenticated;
