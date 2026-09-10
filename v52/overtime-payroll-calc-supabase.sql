-- V5.2 薪資計算設定與加班費試算資料庫變更（測試版已套用）
-- 目的：薪資基數版本化、休息日／國定假日／例假日分類、月結更正金額計算。

-- 1. staff_payroll_rates
-- 欄位：staff_id、effective_from、monthly_wage_base、note、created_by/name、created_at
-- RLS：本人可讀自己的薪資基數；organization_manager/admin 可讀全部並新增。
-- 不開放 UPDATE/DELETE；同一生效日可再新增新版本，查詢時以最後建立版本為準。

-- 2. overtime_requests.request_type 新增：
-- rest_day_overtime / national_holiday_overtime / regular_day_off_overtime
-- 舊 holiday_overtime 保留供歷史資料識別，但新表單不再提供。
-- regular_day_off_overtime 強制 compensation_method='overtime_pay' 且 emergency_basis_confirmed=true。

-- 3. payroll_settlement_corrections 新增：
-- work_date / workday_type / calculated_amount
-- adjustment_type='overtime_pay' 時由 trigger 依該日期有效薪資基數自動計算金額。

-- 4. 計算函式：
-- private.payroll_rate_for_date(staff_id,date)
-- private.calculate_overtime_amount(monthly,type,minutes)
-- 平日：前2小時 4/3、其後2小時 5/3
-- 休息日：前2小時 4/3、第3-8小時 5/3、第9-12小時 8/3
-- 國定假日：8小時內另加1日工資；第9-10小時 4/3、第11-12小時 5/3
-- 例假日：僅法定例外；8小時內另加1日工資，超過8小時部分按每小時2倍；另須事後補假及24小時內報備。

-- 正式版移植時請重新建立完整 migration，而不是直接複製測試資料。
