-- V5.2 特休到期未休工資自動計算
-- 月薪制：原特休年度終結時適用的月薪正常工資 ÷ 30 × 未休日數。
-- 遞延特休屆期未休時，沿用原特休年度終結時的工資基準。

alter table public.annual_leave_settlement_events
  add column if not exists wage_basis_credit_id uuid,
  add column if not exists wage_basis_date date,
  add column if not exists payroll_rate_id uuid,
  add column if not exists payroll_rate_effective_from date,
  add column if not exists monthly_wage_base numeric(12,2),
  add column if not exists daily_wage numeric(12,4),
  add column if not exists calculated_amount numeric(12,2),
  add column if not exists calculation_formula text,
  add column if not exists calculation_version smallint;

CREATE OR REPLACE FUNCTION private.annual_leave_cash_settlement_quote_core(p_credit_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid;
  v_credit public.annual_leave_credits%rowtype;
  v_basis public.annual_leave_credits%rowtype;
  v_rate public.staff_payroll_rates%rowtype;
  v_days numeric(10,6);
  v_days_text text;
  v_daily_wage numeric;
  v_raw_amount numeric;
  v_amount numeric;
  v_hops integer := 0;
  v_today date := ((now() at time zone 'Asia/Taipei')::date);
begin
  v_uid := (select auth.uid());
  if v_uid is null then raise exception '尚未登入'; end if;
  if not coalesce(private.can_manage_annual_leave(),false) then
    raise exception '目前帳號沒有特休到期處理權限';
  end if;

  select * into v_credit
  from public.annual_leave_credits
  where id=p_credit_id;

  if not found then raise exception '找不到指定的特休額度'; end if;
  if v_credit.settlement_status<>'pending_settlement' then
    raise exception '此特休目前不是待處理狀態';
  end if;
  if v_credit.period_end>=v_today then
    raise exception '此特休尚未到期';
  end if;

  v_days := coalesce(v_credit.remaining_days,0);
  if v_days<=0 then raise exception '此特休已無待處理天數'; end if;
  v_days_text := trim(trailing '.' from trim(trailing '0' from v_days::text));

  v_basis := v_credit;
  while v_basis.generation_source='carryover' and v_basis.source_credit_id is not null loop
    select * into v_basis
    from public.annual_leave_credits
    where id=v_basis.source_credit_id;

    if not found then
      raise exception '找不到遞延特休的原始批次，無法計算未休工資';
    end if;

    v_hops := v_hops + 1;
    if v_hops>10 then
      raise exception '特休遞延來源鏈異常，無法計算未休工資';
    end if;
  end loop;

  select * into v_rate
  from public.staff_payroll_rates r
  where r.staff_id=v_credit.staff_id
    and r.effective_from<=v_basis.period_end
  order by r.effective_from desc,r.created_at desc
  limit 1;

  if not found then
    raise exception '該員工於特休原年度終結日前尚未設定有效的月薪工資基數，請先至薪資計算設定補齊';
  end if;

  if v_rate.monthly_wage_base is null or v_rate.monthly_wage_base<=0 then
    raise exception '月薪工資基數不正確，無法計算未休特休工資';
  end if;

  v_daily_wage := v_rate.monthly_wage_base/30.0;
  v_raw_amount := v_days*v_daily_wage;
  v_amount := round(v_raw_amount,0);

  return jsonb_build_object(
    'credit_id',v_credit.id,
    'staff_id',v_credit.staff_id,
    'days',v_days,
    'wage_basis_credit_id',v_basis.id,
    'wage_basis_date',v_basis.period_end,
    'payroll_rate_id',v_rate.id,
    'payroll_rate_effective_from',v_rate.effective_from,
    'monthly_wage_base',round(v_rate.monthly_wage_base,2),
    'daily_wage',round(v_daily_wage,4),
    'raw_amount',round(v_raw_amount,2),
    'calculated_amount',v_amount,
    'calculation_formula',
      trim(to_char(v_rate.monthly_wage_base,'FM9999999990.00'))
      || ' ÷ 30 × '
      || v_days_text
      || '日 = '
      || trim(to_char(v_amount,'FM9999999990'))
      || '元',
    'calculation_version',1
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.annual_leave_cash_settlement_quote(p_credit_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select private.annual_leave_cash_settlement_quote_core(p_credit_id);
$function$;

revoke all on function public.annual_leave_cash_settlement_quote(uuid) from public;
revoke all on function public.annual_leave_cash_settlement_quote(uuid) from anon;
grant execute on function public.annual_leave_cash_settlement_quote(uuid) to authenticated;

CREATE OR REPLACE FUNCTION private.resolve_annual_leave_expiry_core(p_credit_id uuid, p_action text, p_agreement_date date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid;
  v_name text;
  v_credit public.annual_leave_credits%rowtype;
  v_minutes integer;
  v_days numeric(10,6);
  v_today date := ((now() at time zone 'Asia/Taipei')::date);
  v_next_start date;
  v_next_end date;
  v_child_id uuid;
  v_quote jsonb;
begin
  v_uid := (select auth.uid());
  if v_uid is null then raise exception '尚未登入'; end if;
  if not coalesce(private.can_manage_annual_leave(),false) then
    raise exception '目前帳號沒有特休到期處理權限';
  end if;

  v_name := coalesce(private.current_staff_user_name(),'管理者');

  select * into v_credit
  from public.annual_leave_credits
  where id=p_credit_id
  for update;

  if not found then raise exception '找不到指定的特休額度'; end if;
  if v_credit.settlement_status<>'pending_settlement' then
    raise exception '此特休目前不是待處理狀態';
  end if;
  if v_credit.period_end>=v_today then
    raise exception '此特休尚未到期';
  end if;

  v_days := coalesce(v_credit.remaining_days,0);
  v_minutes := case
    when v_credit.daily_hours_snapshot is not null and v_credit.daily_hours_snapshot>0
      then round(v_days*v_credit.daily_hours_snapshot*60)::integer
    else coalesce(v_credit.remaining_minutes,0)
  end;

  if v_days<=0 then raise exception '此特休已無待處理天數'; end if;

  if p_action='cash_settlement' then
    v_quote := private.annual_leave_cash_settlement_quote_core(v_credit.id);

    update public.annual_leave_credits
    set remaining_days=0,
        remaining_minutes=0,
        settlement_status='settled',
        updated_at=now()
    where id=v_credit.id;

    insert into public.annual_leave_settlement_events(
      credit_id,staff_id,action,days,minutes,agreement_date,note,
      processed_by,processed_by_name,carryover_credit_id,
      wage_basis_credit_id,wage_basis_date,payroll_rate_id,payroll_rate_effective_from,
      monthly_wage_base,daily_wage,calculated_amount,calculation_formula,calculation_version
    ) values (
      v_credit.id,v_credit.staff_id,'cash_settlement',v_days,v_minutes,null,
      nullif(trim(coalesce(p_note,'')),''),
      v_uid,v_name,null,
      (v_quote->>'wage_basis_credit_id')::uuid,
      (v_quote->>'wage_basis_date')::date,
      (v_quote->>'payroll_rate_id')::uuid,
      (v_quote->>'payroll_rate_effective_from')::date,
      (v_quote->>'monthly_wage_base')::numeric,
      (v_quote->>'daily_wage')::numeric,
      (v_quote->>'calculated_amount')::numeric,
      v_quote->>'calculation_formula',
      (v_quote->>'calculation_version')::smallint
    );

    return v_quote || jsonb_build_object(
      'action','cash_settlement',
      'minutes',v_minutes
    );

  elsif p_action='carryover' then
    if v_credit.generation_source='carryover' then
      raise exception '遞延特休到期後不得再次遞延，請辦理工資結清';
    end if;
    if p_agreement_date is null then
      raise exception '協議遞延必須填寫勞雇雙方同意日期';
    end if;
    if p_agreement_date>v_today then
      raise exception '同意日期不可晚於今日';
    end if;

    v_next_start := v_credit.period_end+1;
    v_next_end := (v_credit.period_end+interval '1 year')::date;
    if v_today>v_next_end then
      raise exception '已超過可遞延的下一年度期間，請辦理工資結清';
    end if;

    insert into public.annual_leave_credits(
      staff_id,period_start,period_end,
      granted_days,remaining_days,
      granted_minutes,remaining_minutes,
      label,note,created_by,created_by_name,
      entitlement_key,entitlement_days,daily_hours_snapshot,
      generation_source,settlement_status,auto_generated_at,source_credit_id
    ) values (
      v_credit.staff_id,v_next_start,v_next_end,
      v_days,v_days,
      v_minutes,v_minutes,
      '遞延特休｜'||coalesce(v_credit.label,'原特休'),
      '由到期特休遞延；來源批次：'
        ||coalesce(v_credit.label,'特休')
        ||'（'||v_credit.period_start::text||'～'||v_credit.period_end::text||'）',
      v_uid,v_name,
      'carryover:'||v_credit.id::text,
      v_days,v_credit.daily_hours_snapshot,
      'carryover','active',null,v_credit.id
    )
    returning id into v_child_id;

    update public.annual_leave_credits
    set remaining_days=0,
        remaining_minutes=0,
        settlement_status='carried_over',
        updated_at=now()
    where id=v_credit.id;

    insert into public.annual_leave_settlement_events(
      credit_id,staff_id,action,days,minutes,agreement_date,note,
      processed_by,processed_by_name,carryover_credit_id
    ) values (
      v_credit.id,v_credit.staff_id,'carryover',v_days,v_minutes,p_agreement_date,
      nullif(trim(coalesce(p_note,'')),''),
      v_uid,v_name,v_child_id
    );

    return jsonb_build_object(
      'action','carryover',
      'days',v_days,
      'minutes',v_minutes,
      'credit_id',v_credit.id,
      'carryover_credit_id',v_child_id,
      'period_start',v_next_start,
      'period_end',v_next_end
    );
  else
    raise exception '不支援的處理方式';
  end if;
exception
  when unique_violation then
    raise exception '此批特休已完成到期處理，請重新整理後確認';
end;
$function$;
