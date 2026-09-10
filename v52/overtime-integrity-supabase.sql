-- V5.2 加班／換休資料完整性
-- 目的：
-- 1. 已月結月份禁止再新增或修改加班／換休資料。
-- 2. 已核准但尚未月結的錯誤紀錄可作廢，保留原始紀錄與作廢原因。
-- 3. 若作廢會造成換休已使用時數超過可用時數，系統阻止作廢。

alter table public.overtime_requests
  add column if not exists void_reason text,
  add column if not exists voided_by uuid references auth.users(id) on delete set null,
  add column if not exists voided_at timestamptz;

alter table public.comp_leave_usages
  add column if not exists void_reason text,
  add column if not exists voided_by uuid references auth.users(id) on delete set null,
  add column if not exists voided_at timestamptz;

alter table public.overtime_requests drop constraint if exists overtime_requests_status_check;
alter table public.overtime_requests
  add constraint overtime_requests_status_check
  check (status = any (array['draft'::text,'pending'::text,'approved'::text,'rejected'::text,'voided'::text]));

alter table public.comp_leave_usages drop constraint if exists comp_leave_usages_status_check;
alter table public.comp_leave_usages
  add constraint comp_leave_usages_status_check
  check (status = any (array['draft'::text,'pending'::text,'approved'::text,'rejected'::text,'voided'::text]));

create or replace function private.payroll_month_is_settled(p_date date)
returns boolean language sql stable security definer set search_path=''
as $$
  select exists (
    select 1 from public.payroll_month_settlements p
    where p.settlement_month = date_trunc('month', p_date::timestamp)::date
  );
$$;
revoke all on function private.payroll_month_is_settled(date) from public, anon, authenticated;

create or replace function public.is_payroll_month_settled(p_date date)
returns boolean language sql stable security definer set search_path=''
as $$ select private.payroll_month_is_settled(p_date); $$;
revoke all on function public.is_payroll_month_settled(date) from public, anon;
grant execute on function public.is_payroll_month_settled(date) to authenticated;

create or replace function private.enforce_open_payroll_month()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_new_date date; v_old_date date;
begin
  if tg_table_name='overtime_requests' then
    v_new_date:=new.work_date;
    if tg_op='UPDATE' then v_old_date:=old.work_date; end if;
  elsif tg_table_name='comp_leave_usages' then
    v_new_date:=new.leave_date;
    if tg_op='UPDATE' then v_old_date:=old.leave_date; end if;
  else return new;
  end if;

  if tg_op='UPDATE' and v_old_date is not null and private.payroll_month_is_settled(v_old_date) then
    raise exception '該月份已完成薪資結算，資料已鎖定，不能再修改。' using errcode='P0001';
  end if;
  if v_new_date is not null and private.payroll_month_is_settled(v_new_date) then
    raise exception '該月份已完成薪資結算，不能新增或移入該月份資料。' using errcode='P0001';
  end if;
  return new;
end;
$$;
revoke all on function private.enforce_open_payroll_month() from public, anon, authenticated;

drop trigger if exists overtime_requests_open_month_guard on public.overtime_requests;
create trigger overtime_requests_open_month_guard before insert or update on public.overtime_requests
for each row execute function private.enforce_open_payroll_month();

drop trigger if exists comp_leave_usages_open_month_guard on public.comp_leave_usages;
create trigger comp_leave_usages_open_month_guard before insert or update on public.comp_leave_usages
for each row execute function private.enforce_open_payroll_month();

-- 實際的作廢 RPC 已於測試 Supabase migration：overtime_month_lock_and_void_workflow_v52 建立。
-- 正式版移植時，應以 Supabase migration 紀錄中的完整版本為準，勿只執行本檔片段。