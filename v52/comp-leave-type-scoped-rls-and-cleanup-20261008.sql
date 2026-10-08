-- Refactor existing RLS checks to the selected comp-leave type; preserve all role/status rules.
CREATE OR REPLACE FUNCTION private.comp_leave_available_minutes_typed(
 p_staff_id uuid,p_leave_type text,p_exclude_usage_id uuid,p_as_of date)
RETURNS integer LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $body$
DECLARE
 v_current_staff uuid;
 v_can_review boolean;
 v_available integer:=0;
 v_pending integer:=0;
 v_today date:=((now() at time zone 'Asia/Taipei')::date);
 v_usage_date date:=coalesce(p_as_of,v_today);
BEGIN
 IF (SELECT auth.uid()) IS NULL THEN RETURN 0; END IF;
 IF p_leave_type NOT IN('ordinary','holiday_visit') OR p_leave_type IS NULL THEN RETURN 0; END IF;
 v_current_staff:=private.current_staff_user_id();
 v_can_review:=private.can_review_overtime();
 IF p_staff_id IS DISTINCT FROM v_current_staff AND NOT coalesce(v_can_review,false) THEN RETURN 0; END IF;
 SELECT coalesce(sum(c.remaining_minutes),0)::integer INTO v_available
 FROM public.comp_leave_credits c
 WHERE c.staff_id=p_staff_id AND c.leave_type=p_leave_type
   AND c.earned_date<=least(v_today,v_usage_date) AND c.remaining_minutes>0
   AND (c.expires_on IS NULL OR c.expires_on>=v_usage_date);
 SELECT coalesce(sum(u.minutes),0)::integer INTO v_pending
 FROM public.comp_leave_usages u
 WHERE u.applicant_staff_id=p_staff_id AND u.leave_type=p_leave_type
   AND u.status='pending'
   AND (p_exclude_usage_id IS NULL OR u.id<>p_exclude_usage_id);
 RETURN greatest(v_available-v_pending,0);
END;
$body$;

REVOKE ALL ON FUNCTION private.comp_leave_available_minutes_typed(uuid,text,uuid,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.comp_leave_available_minutes_typed(uuid,text,uuid,date) TO authenticated;

DO $body$
DECLARE v_policy text; v_check text;
BEGIN
 FOR v_policy IN SELECT unnest(ARRAY['comp_leave_insert_own','comp_leave_update_applicant_or_reviewer'])
 LOOP
   SELECT with_check INTO v_check FROM pg_policies
   WHERE schemaname='public' AND tablename='comp_leave_usages' AND policyname=v_policy;
   IF v_check IS NULL THEN RAISE EXCEPTION 'Missing existing RLS policy %',v_policy; END IF;
   v_check:=replace(v_check,
     'private.comp_leave_available_minutes(applicant_staff_id, NULL::uuid, leave_date)',
     'private.comp_leave_available_minutes_typed(applicant_staff_id, leave_type, NULL::uuid, leave_date)');
   v_check:=replace(v_check,
     'private.comp_leave_available_minutes(applicant_staff_id, id, leave_date)',
     'private.comp_leave_available_minutes_typed(applicant_staff_id, leave_type, id, leave_date)');
   IF position('private.comp_leave_available_minutes(' in v_check)>0 THEN
     RAISE EXCEPTION 'Unreplaced legacy RLS comp leave balance call in %',v_policy;
   END IF;
   EXECUTE format('ALTER POLICY %I ON public.comp_leave_usages WITH CHECK (%s)',v_policy,v_check);
 END LOOP;
END;
$body$;

-- No CASCADE: fail rather than deleting any security policy or dependent object.
DROP FUNCTION IF EXISTS private.allocate_comp_leave_debit(uuid,date,integer,text,uuid);
DROP FUNCTION IF EXISTS private.comp_leave_available_minutes(uuid,uuid);
DROP FUNCTION IF EXISTS private.comp_leave_available_minutes(uuid,uuid,date);
REVOKE ALL ON FUNCTION private.allocate_comp_leave_debit_typed(uuid,date,integer,text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.allocate_comp_leave_debit_typed(uuid,date,integer,text,uuid,text) FROM anon;
REVOKE ALL ON FUNCTION private.allocate_comp_leave_debit_typed(uuid,date,integer,text,uuid,text) FROM authenticated;
COMMENT ON COLUMN public.comp_leave_usages.leave_type IS 'One usage deducts only ordinary or holiday_visit credits, never both.';
COMMENT ON COLUMN public.comp_leave_credits.leave_type IS 'Independent ordinary or holiday_visit earned source account.';