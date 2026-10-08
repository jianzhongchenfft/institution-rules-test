-- TEST DB only: lunch break 12:00-13:00 does not consume comp leave.
-- Calendar leave start/end remain the original clock times; minutes are net work minutes.
CREATE OR REPLACE FUNCTION private.comp_leave_charge_minutes(p_start time without time zone, p_end time without time zone)
RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN 0
    ELSE (
      (EXTRACT(EPOCH FROM (p_end-p_start)) / 60)::integer
      - GREATEST(
          (EXTRACT(EPOCH FROM (LEAST(p_end,time '13:00')-GREATEST(p_start,time '12:00'))) / 60)::integer,0
        )
    )
  END
$function$;

ALTER TABLE public.comp_leave_usages
  DROP CONSTRAINT comp_leave_usages_minutes_match_time_check;
ALTER TABLE public.comp_leave_usages
  ADD CONSTRAINT comp_leave_usages_minutes_match_time_check
  CHECK (minutes = private.comp_leave_charge_minutes(start_time,end_time));

-- Payroll correction preview is authoritative for the stored correction amount.
-- Preserve the existing overlap, permissions, source reconciliation and month guards.
DO $body$
DECLARE f text; new_f text;
  old_sql text:='  v_minutes:=v_end-v_start;';
  new_sql text:='  v_minutes:=v_end-v_start - greatest(least(v_end,780)-greatest(v_start,720),0);'||chr(10)||
    '  if v_minutes<=0 then'||chr(10)||
    '    raise exception ''申請區間僅涵蓋12:00～13:00午休，無可扣抵換休時數。'' using errcode=''P0001'';'||chr(10)||
    '  end if;';
BEGIN
 SELECT pg_get_functiondef(p.oid) INTO f
   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname='payroll_comp_leave_used_preview_core';
 IF f IS NULL OR (length(f)-length(replace(f,old_sql,'')))/length(old_sql)<>1 THEN
   RAISE EXCEPTION 'Expected exactly one payroll used preview duration formula';
 END IF;
 new_f:=replace(f,old_sql,new_sql);
 EXECUTE new_f;
END;
$body$;

COMMENT ON FUNCTION private.comp_leave_charge_minutes(time without time zone,time without time zone)
 IS 'Comp-leave net minutes excluding overlap with 12:00 to 13:00 lunch; one-day intervals only.';