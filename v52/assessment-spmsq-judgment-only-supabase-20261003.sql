-- LiuXinZi TEST / SPMSQ judgment-only refactor
-- 2026-10-03
-- Production use requires separate explicit approval.
-- Existing assessment data in TEST is disposable; raw SPMSQ responses are cleared.

alter table public.assessment_spmsq_records
  add column if not exists notes jsonb not null default '{}'::jsonb;

update public.assessment_spmsq_records
set responses='{}'::jsonb
where responses <> '{}'::jsonb;

delete from public.assessment_spmsq_history
where field_name like 'responses.%';

drop function if exists public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid);

CREATE OR REPLACE FUNCTION public.save_assessment_spmsq(p_event_id uuid, p_judgments jsonb, p_notes jsonb, p_finalize boolean DEFAULT false, p_unable boolean DEFAULT false, p_unable_reason text DEFAULT NULL::text, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_spmsq_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_spmsq_records;
  v_old public.assessment_spmsq_records;
  v_key text;
  v_keys text[] := array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10'];
  v_judgment text;
  v_error_count integer := 0;
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

  p_judgments := coalesce(p_judgments,'{}'::jsonb);
  p_notes := coalesce(p_notes,'{}'::jsonb);
  p_unable_reason := nullif(btrim(p_unable_reason),'');

  if p_unable and p_unable_reason is null then
    raise exception 'SPMSQ_UNABLE_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_judgment := p_judgments ->> v_key;

    if v_judgment is not null
       and v_judgment not in ('correct','wrong','unable_answer') then
      raise exception 'INVALID_SPMSQ_JUDGMENT:%', v_key;
    end if;

    if not p_unable then
      if p_finalize and v_judgment is null then
        raise exception 'SPMSQ_JUDGMENT_INCOMPLETE:%', v_key;
      end if;

      if v_judgment in ('wrong','unable_answer') then
        v_error_count := v_error_count + 1;
      end if;
    end if;
  end loop;

  select * into v_old
  from public.assessment_spmsq_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_spmsq_records(
      assessment_event_id,case_id,responses,judgments,notes,error_count,is_unable,unable_reason,
      copied_from_id,copied_at,confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,'{}'::jsonb,p_judgments,p_notes,
      case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
      p_unable,p_unable_reason,p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.judgments,'{}'::jsonb)||p_judgments) as t(key)
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

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb)||p_notes) as t(key)
    loop
      if (v_old.notes->v_key) is distinct from (p_notes->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'notes.'||v_key,
          v_old.notes->v_key,p_notes->v_key,(select auth.uid())
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
    set responses='{}'::jsonb,
        judgments=p_judgments,
        notes=p_notes,
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
  set status=case
      when p_finalize and p_unable then 'unable'
      when p_finalize then 'completed'
      else 'in_progress'
    end,
    updated_at=now()
  where assessment_event_id=p_event_id
    and form_code='spmsq';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;

revoke all on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) from public;
revoke all on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) from anon;
grant execute on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) to authenticated;
