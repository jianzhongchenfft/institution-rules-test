-- V5.2 月薪資結算報表／已結算鎖定
-- 先於測試 Supabase 執行；正式版驗收後再套用同一份結構。

create table if not exists public.payroll_month_settlements (
  id uuid primary key default gen_random_uuid(),
  settlement_month date not null unique,
  summary jsonb not null default '{"staff":[],"totals":{}}'::jsonb,
  total_overtime_pay_minutes integer not null default 0 check (total_overtime_pay_minutes >= 0),
  total_comp_leave_earned_minutes integer not null default 0 check (total_comp_leave_earned_minutes >= 0),
  total_comp_leave_used_minutes integer not null default 0 check (total_comp_leave_used_minutes >= 0),
  settled_by uuid not null references auth.users(id),
  settled_by_name text not null,
  settled_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint payroll_month_settlements_month_start_check
    check (settlement_month = date_trunc('month', settlement_month)::date),
  constraint payroll_month_settlements_summary_object_check
    check (jsonb_typeof(summary) = 'object')
);

alter table public.payroll_month_settlements enable row level security;

grant select, insert on table public.payroll_month_settlements to authenticated;

drop policy if exists payroll_settlements_read_reviewer on public.payroll_month_settlements;
create policy payroll_settlements_read_reviewer
on public.payroll_month_settlements
for select
to authenticated
using ((select private.can_review_overtime()));

drop policy if exists payroll_settlements_insert_reviewer on public.payroll_month_settlements;
create policy payroll_settlements_insert_reviewer
on public.payroll_month_settlements
for insert
to authenticated
with check (
  (select private.can_review_overtime())
  and settled_by = (select auth.uid())
  and settled_by_name = (select private.current_staff_user_name())
);

create index if not exists payroll_month_settlements_settled_by_idx
  on public.payroll_month_settlements(settled_by);

-- 不建立 UPDATE / DELETE policy：
-- 月結一旦寫入即為唯讀快照，達成「已結算鎖定」。
