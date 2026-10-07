-- Attendance V2 anniversary core cleanup
-- 2026-10-07
-- Canonical TEST migration for:
-- 1) one shared anniversary-period calculation
-- 2) system-generated annual leave credits only
-- 3) controlled carryover flow
-- 4) comp-leave expiry using the same anniversary core
-- Existing test attendance data was cleared separately and is intentionally not deleted by this file.

create or replace function private.staff_anniversary_period(
  p_staff_id uuid,
  p_reference_date date
)
returns table(
  period_start date,
  period_end date,
  service_years integer
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_hire date;
  v_years integer;
  v_start date;
begin
  if p_staff_id is null or p_reference_date is null then
    return;
  end if;

  select s.hire_date
    into v_hire
  from public.staff_users s
  where s.id = p_staff_id;

  if v_hire is null or p_reference_date < v_hire then
    return;
  end if;

  v_years := greatest(extract(year from age(p_reference_date, v_hire))::integer, 0);
  v_start := (v_hire + make_interval(years => v_years))::date;

  if p_reference_date < v_start then
    v_years := greatest(v_years - 1, 0);
    v_start := (v_hire + make_interval(years => v_years))::date;
  end if;

  return query
  select
    v_start,
    (v_start + interval '1 year' - interval '1 day')::date,
    v_years;
end;
$$;

revoke all on function private.staff_anniversary_period(uuid,date) from public, anon, authenticated;

create or replace function private.generate_annual_leave_credits(
  p_as_of date default ((now() at time zone 'Asia/Taipei')::date)
)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_staff record;
  v_period record;
  v_days numeric(6,2);
  v_daily_hours numeric(6,2);
  v_start date;
  v_end date;
  v_key text;
  v_label text;
  v_minutes integer;
  v_inserted integer := 0;
begin
  update public.annual_leave_credits c
  set settlement_status = case
        when c.remaining_minutes > 0 then 'pending_settlement'
        else 'settled'
      end,
      updated_at = now()
  where c.period_end < p_as_of
    and c.settlement_status = 'active';

  for v_staff in
    select s.id, s.display_name, s.hire_date, s.agreed_daily_hours
    from public.staff_users s
    where s.is_active = true
      and s.hire_date is not null
  loop
    v_start := null;
    v_end := null;
    v_key := null;
    v_label := null;
    v_days := 0;
    v_daily_hours := null;

    select *
      into v_period
    from private.staff_anniversary_period(v_staff.id, p_as_of)
    limit 1;

    if v_period.period_end is null then
      continue;
    end if;

    if p_as_of >= (v_staff.hire_date + interval '6 months')::date
       and p_as_of < (v_staff.hire_date + interval '1 year')::date then
      v_start := (v_staff.hire_date + interval '6 months')::date;
      v_end := v_period.period_end;
      v_key := 'anniversary:m6:' || to_char(v_start,'YYYY-MM-DD');
      v_label := '滿半年特休';
      v_days := 3;
    elsif v_period.service_years >= 1 then
      v_start := v_period.period_start;
      v_end := v_period.period_end;
      v_days := private.annual_leave_days_for_years(v_period.service_years);
      v_key := 'anniversary:y' || v_period.service_years::text || ':' || to_char(v_start,'YYYY-MM-DD');
      v_label := '滿' || v_period.service_years::text || '年特休';
    end if;

    if v_start is null or v_end is null or v_days <= 0 or p_as_of not between v_start and v_end then
      continue;
    end if;

    select r.agreed_daily_hours
      into v_daily_hours
    from public.staff_payroll_rates r
    where r.staff_id = v_staff.id
      and r.effective_from <= v_start
    order by r.effective_from desc, r.created_at desc
    limit 1;

    v_daily_hours := coalesce(v_daily_hours, v_staff.agreed_daily_hours);
    if v_daily_hours is null or v_daily_hours <= 0 or v_daily_hours > 8 then
      continue;
    end if;

    v_minutes := round(v_days * v_daily_hours * 60)::integer;

    insert into public.annual_leave_credits(
      staff_id, period_start, period_end, granted_minutes, remaining_minutes,
      label, note, created_by, created_by_name, entitlement_key,
      entitlement_days, daily_hours_snapshot, generation_source,
      settlement_status, auto_generated_at
    ) values (
      v_staff.id, v_start, v_end, v_minutes, v_minutes,
      v_label,
      '週年制自動產生：' || trim(to_char(v_days,'FM999990.##')) ||
        '日 × 約定每日' || trim(to_char(v_daily_hours,'FM999990.##')) || '小時',
      null, '系統自動產生', v_key,
      v_days, v_daily_hours, 'auto_weekly_anniversary',
      'active', now()
    )
    on conflict (staff_id, entitlement_key) where entitlement_key is not null
    do nothing;

    if found then
      v_inserted := v_inserted + 1;
    end if;
  end loop;

  return v_inserted;
end;
$$;

create or replace function private.sync_overtime_comp_leave_credit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
  v_bad integer;
  v_expiry date;
begin
  if tg_op='UPDATE'
     and old.status='approved'
     and old.compensation_method='comp_leave'
     and not (new.status='approved' and new.compensation_method='comp_leave') then
    select count(*)::integer
      into v_bad
    from public.comp_leave_credits c
    where c.source_type='overtime_request'
      and c.source_id=old.id
      and c.remaining_minutes<c.earned_minutes;

    if v_bad>0 then
      raise exception '此換休來源已有使用紀錄，不能直接作廢；請先處理已使用換休';
    end if;

    delete from public.comp_leave_credits
    where source_type='overtime_request'
      and source_id=old.id;

    return new;
  end if;

  if new.status='approved' and new.compensation_method='comp_leave' then
    select count(*)::integer
      into v_bad
    from public.comp_leave_credits c
    where c.source_type='overtime_request'
      and c.source_id=new.id
      and c.remaining_minutes<c.earned_minutes;

    if v_bad>0 then
      raise exception '此換休來源已有使用紀錄，不能重新建立來源';
    end if;

    delete from public.comp_leave_credits
    where source_type='overtime_request'
      and source_id=new.id;

    if new.request_type='holiday_visit_comp' then
      v_total:=coalesce(new.comp_minutes,0);
      if v_total>0 then
        insert into public.comp_leave_credits(
          staff_id,source_type,source_id,earned_date,
          earned_minutes,remaining_minutes,expires_on,source_label
        )
        values(
          new.applicant_staff_id,'overtime_request',new.id,new.work_date,
          v_total,v_total,null,'假日家訪換休'
        );
      end if;
      return new;
    end if;

    v_total:=coalesce(new.overtime_minutes,0);
    if v_total>0 then
      select p.period_end
        into v_expiry
      from private.staff_anniversary_period(new.applicant_staff_id,new.work_date) p
      limit 1;

      insert into public.comp_leave_credits(
        staff_id,source_type,source_id,earned_date,
        earned_minutes,remaining_minutes,expires_on,source_label
      )
      values(
        new.applicant_staff_id,'overtime_request',new.id,new.work_date,
        v_total,v_total,v_expiry,'加班換休'
      );
    end if;
  end if;

  return new;
end;
$$;

create or replace function private.sync_payroll_correction_comp_leave()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date date;
  v_minutes integer;
  v_expiry date;
  v_label text;
begin
  if new.adjustment_type='overtime_pay' then return new; end if;

  if new.adjustment_type='comp_leave_earned' then
    v_date:=new.work_date;
    if v_date is null then raise exception '換休取得更正缺少實際取得日期'; end if;

    if new.adjustment_minutes>0 then
      v_minutes:=new.adjustment_minutes;

      if new.workday_type='holiday_visit_comp' then
        v_expiry:=null;
        v_label:='月結更正－假日家訪換休';
      else
        select p.period_end
          into v_expiry
        from private.staff_anniversary_period(new.staff_id,v_date) p
        limit 1;
        v_label:='月結更正－加班換休';
      end if;

      insert into public.comp_leave_credits(
        staff_id,source_type,source_id,earned_date,
        earned_minutes,remaining_minutes,expires_on,source_label
      )
      values(
        new.staff_id,'payroll_correction_earned',new.id,v_date,
        v_minutes,v_minutes,v_expiry,v_label
      )
      on conflict(source_type,source_id,earned_date) do nothing;
    else
      perform private.allocate_comp_leave_debit_by_workday_type(
        new.staff_id,v_date,abs(new.adjustment_minutes),new.id,new.workday_type
      );
    end if;

    return new;
  end if;

  if new.adjustment_type='comp_leave_used' then
    v_date:=new.work_date;
    if v_date is null then raise exception '換休使用更正缺少實際使用日期'; end if;

    if new.adjustment_minutes>0 then
      perform private.allocate_comp_leave_debit(
        new.staff_id,v_date,new.adjustment_minutes,'payroll_correction',new.id
      );
    else
      perform private.restore_comp_leave_debit_as_correction(
        new.id,new.related_source_type,new.related_source_id
      );
    end if;
  end if;

  return new;
end;
$$;

create or replace function private.refresh_staff_comp_leave_expiry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.hire_date is distinct from old.hire_date then
    update public.comp_leave_credits c
    set expires_on = case
          when c.source_type='overtime_request'
            and exists(
              select 1
              from public.overtime_requests o
              where o.id=c.source_id
                and o.request_type='holiday_visit_comp'
            )
          then null
          else (
            select p.period_end
            from private.staff_anniversary_period(c.staff_id,c.earned_date) p
            limit 1
          )
        end,
        updated_at=now()
    where c.staff_id=new.id;
  end if;

  return new;
end;
$$;

drop function if exists private.comp_leave_expiry_date(uuid,date);

create or replace function private.resolve_annual_leave_expiry_core(
  p_credit_id uuid,
  p_action text,
  p_agreement_date date default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_name text;
  v_credit public.annual_leave_credits%rowtype;
  v_minutes integer;
  v_today date := ((now() at time zone 'Asia/Taipei')::date);
  v_next_start date;
  v_next_end date;
  v_child_id uuid;
  v_days numeric(8,2);
begin
  v_uid := (select auth.uid());
  if v_uid is null then raise exception '尚未登入'; end if;
  if not coalesce(private.can_manage_annual_leave(),false) then
    raise exception '目前帳號沒有特休到期處理權限';
  end if;

  v_name := coalesce(private.current_staff_user_name(),'管理者');

  select *
    into v_credit
  from public.annual_leave_credits
  where id=p_credit_id
  for update;

  if not found then raise exception '找不到指定的特休額度'; end if;
  if v_credit.settlement_status<>'pending_settlement' then raise exception '此特休目前不是待處理狀態'; end if;
  if v_credit.period_end>=v_today then raise exception '此特休尚未到期'; end if;

  v_minutes := coalesce(v_credit.remaining_minutes,0);
  if v_minutes<=0 then raise exception '此特休已無待處理時數'; end if;

  if p_action='cash_settlement' then
    update public.annual_leave_credits
    set remaining_minutes=0,
        settlement_status='settled',
        updated_at=now()
    where id=v_credit.id;

    insert into public.annual_leave_settlement_events(
      credit_id,staff_id,action,minutes,agreement_date,note,
      processed_by,processed_by_name,carryover_credit_id
    )
    values(
      v_credit.id,v_credit.staff_id,'cash_settlement',v_minutes,null,
      nullif(trim(coalesce(p_note,'')),''),
      v_uid,v_name,null
    );

    return jsonb_build_object(
      'action','cash_settlement',
      'minutes',v_minutes,
      'credit_id',v_credit.id
    );

  elsif p_action='carryover' then
    if v_credit.generation_source='carryover' then
      raise exception '遞延特休到期後不得再次遞延，請辦理工資結清';
    end if;
    if p_agreement_date is null then raise exception '協議遞延必須填寫勞雇雙方同意日期'; end if;
    if p_agreement_date>v_today then raise exception '同意日期不可晚於今日'; end if;

    v_next_start := v_credit.period_end+1;
    v_next_end := (v_credit.period_end+interval '1 year')::date;
    if v_today>v_next_end then raise exception '已超過可遞延的下一年度期間，請辦理工資結清'; end if;

    if v_credit.daily_hours_snapshot is not null and v_credit.daily_hours_snapshot>0 then
      v_days := round((v_minutes::numeric/(v_credit.daily_hours_snapshot*60)),2);
    else
      v_days := null;
    end if;

    insert into public.annual_leave_credits(
      staff_id,period_start,period_end,granted_minutes,remaining_minutes,
      label,note,created_by,created_by_name,entitlement_key,entitlement_days,
      daily_hours_snapshot,generation_source,settlement_status,
      auto_generated_at,source_credit_id
    )
    values(
      v_credit.staff_id,v_next_start,v_next_end,v_minutes,v_minutes,
      '遞延特休｜'||coalesce(v_credit.label,'原特休'),
      '由到期特休遞延；來源批次：'||coalesce(v_credit.label,'特休')||
        '（'||v_credit.period_start::text||'～'||v_credit.period_end::text||'）',
      v_uid,v_name,'carryover:'||v_credit.id::text,v_days,
      v_credit.daily_hours_snapshot,'carryover','active',null,v_credit.id
    )
    returning id into v_child_id;

    update public.annual_leave_credits
    set remaining_minutes=0,
        settlement_status='carried_over',
        updated_at=now()
    where id=v_credit.id;

    insert into public.annual_leave_settlement_events(
      credit_id,staff_id,action,minutes,agreement_date,note,
      processed_by,processed_by_name,carryover_credit_id
    )
    values(
      v_credit.id,v_credit.staff_id,'carryover',v_minutes,p_agreement_date,
      nullif(trim(coalesce(p_note,'')),''),
      v_uid,v_name,v_child_id
    );

    return jsonb_build_object(
      'action','carryover',
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
$$;

revoke all on function private.resolve_annual_leave_expiry_core(uuid,text,date,text) from public, anon;
grant execute on function private.resolve_annual_leave_expiry_core(uuid,text,date,text) to authenticated;

create or replace function public.resolve_annual_leave_expiry(
  p_credit_id uuid,
  p_action text,
  p_agreement_date date default null,
  p_note text default null
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.resolve_annual_leave_expiry_core(
    p_credit_id,p_action,p_agreement_date,p_note
  );
$$;

revoke all on function public.resolve_annual_leave_expiry(uuid,text,date,text) from public, anon;
grant execute on function public.resolve_annual_leave_expiry(uuid,text,date,text) to authenticated;

drop policy if exists annual_leave_credits_insert_manager on public.annual_leave_credits;
drop policy if exists annual_leave_credits_update_manager on public.annual_leave_credits;

revoke insert, update on public.annual_leave_credits from authenticated;

alter table public.annual_leave_credits
  alter column generation_source drop default;

alter table public.annual_leave_credits
  drop constraint if exists annual_leave_credits_generation_source_check;

alter table public.annual_leave_credits
  add constraint annual_leave_credits_generation_source_check
  check (generation_source in ('auto_weekly_anniversary','carryover'));


-- Attendance V2 supporting indexes
create index if not exists comp_leave_correction_restorations_credit_id_idx
  on private.comp_leave_correction_restorations(credit_id);

create index if not exists comp_leave_usages_voided_by_idx
  on public.comp_leave_usages(voided_by)
  where voided_by is not null;

create index if not exists overtime_requests_voided_by_idx
  on public.overtime_requests(voided_by)
  where voided_by is not null;
