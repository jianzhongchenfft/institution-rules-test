-- V5.2 加班／換休：禁止同日加班時段重疊
-- 已套用於 LiuXinZi-TEST。

create or replace function private.enforce_overtime_duplicate_guard()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.status not in ('draft','pending','approved') then return new; end if;

  if new.request_type in ('overtime','holiday_overtime','rest_day_overtime','national_holiday_overtime','regular_day_off_overtime') then
    if exists (
      select 1
      from public.overtime_requests o
      where o.applicant_staff_id = new.applicant_staff_id
        and o.work_date = new.work_date
        and o.status in ('draft','pending','approved')
        and o.id <> new.id
        and o.request_type in ('overtime','holiday_overtime','rest_day_overtime','national_holiday_overtime','regular_day_off_overtime')
        and new.start_time < o.end_time
        and new.end_time > o.start_time
    ) then
      raise exception '同一天的加班時段與既有申請重疊，請調整時間後再申請。' using errcode='P0001';
    end if;
  elsif new.request_type='holiday_visit_comp' then
    if exists (
      select 1
      from public.overtime_requests o
      where o.applicant_staff_id = new.applicant_staff_id
        and o.work_date = new.work_date
        and o.status in ('draft','pending','approved')
        and o.id <> new.id
        and o.request_type='holiday_visit_comp'
        and o.holiday_case_count is not distinct from new.holiday_case_count
    ) then
      raise exception '同一天相同家訪案數的假日家訪換休已存在，請勿重複送出。' using errcode='P0001';
    end if;
  end if;
  return new;
end;
$function$;
