
-- Independent ordinary / holiday-visit comp leave accounts (test Supabase only).
ALTER TABLE public.comp_leave_credits ADD COLUMN IF NOT EXISTS leave_type text NOT NULL DEFAULT 'ordinary';
ALTER TABLE public.comp_leave_usages ADD COLUMN IF NOT EXISTS leave_type text NOT NULL DEFAULT 'ordinary';
ALTER TABLE public.payroll_settlement_corrections ADD COLUMN IF NOT EXISTS leave_type text;

ALTER TABLE public.comp_leave_credits ADD CONSTRAINT comp_leave_credits_leave_type_check CHECK(leave_type IN('ordinary','holiday_visit'));
ALTER TABLE public.comp_leave_usages ADD CONSTRAINT comp_leave_usages_leave_type_check CHECK(leave_type IN('ordinary','holiday_visit'));
ALTER TABLE public.payroll_settlement_corrections ADD CONSTRAINT payroll_comp_leave_used_type_check
  CHECK(adjustment_type<>'comp_leave_used' OR leave_type IN('ordinary','holiday_visit'));

UPDATE public.comp_leave_credits c SET leave_type='holiday_visit'
WHERE (c.source_type='overtime_request' AND EXISTS(
  SELECT 1 FROM public.overtime_requests o WHERE o.id=c.source_id AND o.request_type='holiday_visit_comp'))
OR (c.source_type='payroll_correction_earned' AND EXISTS(
  SELECT 1 FROM public.payroll_settlement_corrections p WHERE p.id=c.source_id AND p.workday_type='holiday_visit_comp'));

-- Only old comp-leave usage records are test data and were eligible for removal.
-- Restore credits before removing uses and avoid touching other modules.
DO $body$
DECLARE r record;
BEGIN
 FOR r IN SELECT id FROM public.comp_leave_usages LOOP
   PERFORM private.restore_comp_leave_debit('leave_usage',r.id);
 END LOOP;
 DELETE FROM public.comp_leave_usages;
END;
$body$;

CREATE OR REPLACE FUNCTION private.allocate_comp_leave_debit_typed(
 p_staff_id uuid,p_debit_date date,p_minutes integer,p_debit_type text,p_debit_id uuid,p_leave_type text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $body$
DECLARE v_need integer := p_minutes; v_take integer;
  v_cutoff date := least((now() at time zone 'Asia/Taipei')::date,p_debit_date);
  r record;
BEGIN
 IF coalesce(p_minutes,0)<=0 THEN RETURN; END IF;
 IF p_leave_type NOT IN('ordinary','holiday_visit') OR p_leave_type IS NULL THEN
   RAISE EXCEPTION '請選擇有效的換休類型。' USING errcode='P0001';
 END IF;
 IF p_debit_type NOT IN('leave_usage','payroll_correction') THEN
   RAISE EXCEPTION '不支援的換休扣抵類型。' USING errcode='P0001';
 END IF;
 IF EXISTS(SELECT 1 FROM public.comp_leave_allocations a
           WHERE a.debit_type=p_debit_type AND a.debit_id=p_debit_id) THEN RETURN; END IF;
 FOR r IN
   SELECT c.id,c.remaining_minutes FROM public.comp_leave_credits c
   WHERE c.staff_id=p_staff_id AND c.leave_type=p_leave_type
     AND c.earned_date<=v_cutoff AND c.remaining_minutes>0
     AND (c.expires_on IS NULL OR c.expires_on>=p_debit_date)
   ORDER BY c.expires_on NULLS LAST,c.earned_date,c.created_at,c.id
   FOR UPDATE
 LOOP
   EXIT WHEN v_need<=0;
   v_take:=least(v_need,r.remaining_minutes);
   UPDATE public.comp_leave_credits
      SET remaining_minutes=remaining_minutes-v_take,updated_at=now() WHERE id=r.id;
   INSERT INTO public.comp_leave_allocations(credit_id,debit_type,debit_id,allocation_date,minutes)
   VALUES (r.id,p_debit_type,p_debit_id,p_debit_date,v_take);
   v_need:=v_need-v_take;
 END LOOP;
 IF v_need>0 THEN
   RAISE EXCEPTION '所選換休類型的已取得且有效時數不足，請調整時數或另申請另一種類型。' USING errcode='P0001';
 END IF;
END;
$body$;

CREATE OR REPLACE FUNCTION private.validate_comp_leave_usage_balance()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $body$
DECLARE v_cutoff date;v_available integer:=0;v_pending integer:=0;
BEGIN
 IF new.status NOT IN('pending','approved') THEN RETURN new; END IF;
 IF new.leave_date IS NULL OR coalesce(new.minutes,0)<=0 THEN RETURN new; END IF;
 IF new.leave_type NOT IN('ordinary','holiday_visit') OR new.leave_type IS NULL THEN
   RAISE EXCEPTION '請選擇有效的換休類型。' USING errcode='P0001';
 END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.applicant_staff_id::text,0));
 v_cutoff:=least((now() at time zone 'Asia/Taipei')::date,new.leave_date);
 SELECT coalesce(sum(c.remaining_minutes),0)::integer INTO v_available
 FROM public.comp_leave_credits c
 WHERE c.staff_id=new.applicant_staff_id AND c.leave_type=new.leave_type
   AND c.earned_date<=v_cutoff AND c.remaining_minutes>0
   AND (c.expires_on IS NULL OR c.expires_on>=new.leave_date);
 SELECT coalesce(sum(u.minutes),0)::integer INTO v_pending
 FROM public.comp_leave_usages u
 WHERE u.applicant_staff_id=new.applicant_staff_id AND u.leave_type=new.leave_type
   AND u.status='pending' AND u.id<>new.id;
 IF new.minutes>greatest(v_available-v_pending,0) THEN
   RAISE EXCEPTION '所選換休類型可用 % 分鐘，本次申請 % 分鐘；請拆成另一筆換休申請。',
      greatest(v_available-v_pending,0),new.minutes USING errcode='P0001';
 END IF;
 RETURN new;
END;
$body$;

CREATE OR REPLACE FUNCTION private.sync_comp_leave_usage_allocation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $body$
BEGIN
 IF new.status='approved' AND (tg_op='INSERT' OR old.status IS DISTINCT FROM 'approved') THEN
   PERFORM private.allocate_comp_leave_debit_typed(
     new.applicant_staff_id,new.leave_date,new.minutes,'leave_usage',new.id,new.leave_type);
 ELSIF tg_op='UPDATE' AND old.status='approved' AND new.status='voided' THEN
   PERFORM private.restore_comp_leave_debit('leave_usage',new.id);
 END IF;
 RETURN new;
END;
$body$;

DROP TRIGGER IF EXISTS comp_leave_usages_balance_guard ON public.comp_leave_usages;
CREATE TRIGGER comp_leave_usages_balance_guard
 BEFORE INSERT OR UPDATE OF status,leave_date,minutes,leave_type ON public.comp_leave_usages
 FOR EACH ROW EXECUTE FUNCTION private.validate_comp_leave_usage_balance();

-- Rebuild the existing credit and payroll functions from their live definitions,
-- changing only source tagging and the post-settlement usage allocator.
DO $body$
DECLARE f text;
BEGIN
 SELECT pg_get_functiondef(p.oid) INTO f FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname='sync_overtime_comp_leave_credit';
 IF f IS NULL THEN RAISE EXCEPTION 'sync overtime not found'; END IF;
 f:=replace(f,'remaining_minutes,expires_on,source_label)','remaining_minutes,expires_on,source_label,leave_type)');
 f:=replace(f,'null,''假日家訪換休'')','null,''假日家訪換休'',''holiday_visit'')');
 f:=replace(f,'v_expiry,''加班換休'')','v_expiry,''加班換休'',''ordinary'')');
 EXECUTE f;

 SELECT pg_get_functiondef(p.oid) INTO f FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname='sync_payroll_correction_comp_leave';
 IF f IS NULL THEN RAISE EXCEPTION 'sync payroll not found'; END IF;
 f:=replace(f,'remaining_minutes,expires_on,source_label)','remaining_minutes,expires_on,source_label,leave_type)');
 f:=replace(f,'v_expiry,v_label)','v_expiry,v_label,case when new.workday_type=''holiday_visit_comp'' then ''holiday_visit'' else ''ordinary'' end)');
 f:=replace(f,'perform private.allocate_comp_leave_debit(new.staff_id,v_date,new.adjustment_minutes,''payroll_correction'',new.id);',
              'perform private.allocate_comp_leave_debit_typed(new.staff_id,v_date,new.adjustment_minutes,''payroll_correction'',new.id,new.leave_type);');
 EXECUTE f;

 SELECT pg_get_functiondef(p.oid) INTO f FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname='enforce_comp_leave_update_integrity';
 IF f IS NULL THEN RAISE EXCEPTION 'enforce update not found'; END IF;
 f:=replace(f,'begin'||chr(10)||'  if old.status=''approved''',
    'begin'||chr(10)||'  if old.status not in (''draft'',''rejected'') and new.leave_type is distinct from old.leave_type then'||
    chr(10)||'    raise exception ''送出審核後不可變更換休類型。'' using errcode=''P0001'';'||
    chr(10)||'  end if;'||chr(10)||'  if old.status=''approved''');
 EXECUTE f;
END;
$body$;

CREATE OR REPLACE FUNCTION public.preview_payroll_comp_leave_used_typed(
 p_settlement_id uuid,p_staff_id uuid,p_leave_date date,
 p_start_time time without time zone,p_end_time time without time zone,
 p_direction integer,p_leave_type text)
RETURNS TABLE(correction_minutes integer,available_minutes integer,
 related_source_type text,related_source_id uuid,related_source_label text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $body$
DECLARE r record; v_avail integer;
BEGIN
 IF p_leave_type NOT IN('ordinary','holiday_visit') OR p_leave_type IS NULL THEN
   RAISE EXCEPTION '請選擇換休類型。' USING errcode='P0001';
 END IF;
 SELECT * INTO r FROM public.preview_payroll_comp_leave_used_correction(
   p_settlement_id,p_staff_id,p_leave_date,p_start_time,p_end_time,p_direction);
 IF NOT FOUND THEN RAISE EXCEPTION '無法試算換休使用更正。' USING errcode='P0001'; END IF;
 IF p_direction>0 THEN
   SELECT coalesce(sum(c.remaining_minutes),0)::integer INTO v_avail
   FROM public.comp_leave_credits c
   WHERE c.staff_id=p_staff_id AND c.leave_type=p_leave_type
     AND c.earned_date<=least(p_leave_date,(now() at time zone 'Asia/Taipei')::date)
     AND c.remaining_minutes>0 AND (c.expires_on IS NULL OR c.expires_on>=p_leave_date);
   IF v_avail<r.correction_minutes THEN
     RAISE EXCEPTION '所選換休類型時數不足，目前可用 % 分鐘。',v_avail USING errcode='P0001';
   END IF;
   RETURN QUERY SELECT r.correction_minutes::integer,v_avail,NULL::text,NULL::uuid,NULL::text;
 ELSE
   IF (r.related_source_type='leave_usage'
        AND (SELECT u.leave_type FROM public.comp_leave_usages u WHERE u.id=r.related_source_id) IS DISTINCT FROM p_leave_type)
      OR (r.related_source_type='payroll_correction'
        AND (SELECT c.leave_type FROM public.payroll_settlement_corrections c WHERE c.id=r.related_source_id) IS DISTINCT FROM p_leave_type) THEN
     RAISE EXCEPTION '所選換休類型與原始使用紀錄不同。' USING errcode='P0001';
   END IF;
   RETURN QUERY SELECT r.correction_minutes::integer,r.available_minutes::integer,
     r.related_source_type::text,r.related_source_id::uuid,r.related_source_label::text;
 END IF;
END;
$body$;

REVOKE ALL ON FUNCTION public.preview_payroll_comp_leave_used_typed(
 uuid,uuid,date,time without time zone,time without time zone,integer,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_payroll_comp_leave_used_typed(
 uuid,uuid,date,time without time zone,time without time zone,integer,text) TO authenticated;
