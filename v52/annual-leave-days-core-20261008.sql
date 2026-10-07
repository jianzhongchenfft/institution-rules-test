-- Test database migration: annual_leave_days_core_v1
-- Applied to the V5.2 test Supabase project on 2026-10-08.
-- Annual-leave entitlement is stored in days. Minutes remain as compatibility / audit values.

alter table public.annual_leave_credits
  add column if not exists granted_days numeric(10,6),
  add column if not exists remaining_days numeric(10,6);

update public.annual_leave_credits
set granted_days = coalesce(
      granted_days,
      entitlement_days,
      case when daily_hours_snapshot is not null and daily_hours_snapshot > 0
        then round(granted_minutes::numeric / (daily_hours_snapshot * 60), 6) end
    ),
    remaining_days = coalesce(
      remaining_days,
      case when daily_hours_snapshot is not null and daily_hours_snapshot > 0
        then round(remaining_minutes::numeric / (daily_hours_snapshot * 60), 6) end
    );

alter table public.annual_leave_credits
  alter column granted_days set not null,
  alter column remaining_days set not null;

alter table public.annual_leave_credits
  drop constraint if exists annual_leave_credits_days_check;
alter table public.annual_leave_credits
  add constraint annual_leave_credits_days_check
  check (granted_days > 0 and remaining_days >= 0 and remaining_days <= granted_days);

alter table public.annual_leave_requests
  add column if not exists work_hours_snapshot numeric(4,2),
  add column if not exists leave_days numeric(10,6);

alter table public.annual_leave_requests
  drop constraint if exists annual_leave_requests_work_hours_snapshot_check;
alter table public.annual_leave_requests
  add constraint annual_leave_requests_work_hours_snapshot_check
  check (work_hours_snapshot is null or (work_hours_snapshot > 0 and work_hours_snapshot <= 8));

alter table public.annual_leave_requests
  drop constraint if exists annual_leave_requests_leave_days_check;
alter table public.annual_leave_requests
  add constraint annual_leave_requests_leave_days_check
  check (leave_days is null or (leave_days > 0 and leave_days <= 1));

alter table public.annual_leave_allocations
  add column if not exists days numeric(10,6);

alter table public.annual_leave_allocations
  drop constraint if exists annual_leave_allocations_days_check;
alter table public.annual_leave_allocations
  add constraint annual_leave_allocations_days_check
  check (days is null or days > 0);

alter table public.annual_leave_settlement_events
  add column if not exists days numeric(10,6);

create index if not exists staff_work_hours_history_created_by_idx
  on public.staff_work_hours_history(created_by);

-- private.allocate_annual_leave_request
CREATE OR REPLACE FUNCTION private.allocate_annual_leave_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_need_days numeric(10,6);
  v_take_days numeric(10,6);
  v_need_minutes integer;
  v_take_minutes integer;
  v_credit record;
  v_new_remaining_days numeric(10,6);
begin
  if old.status <> 'approved' and new.status = 'approved' then
    v_need_days := new.leave_days;
    v_need_minutes := new.minutes;

    if v_need_days is null or v_need_days <= 0 then
      raise exception '特休扣抵天數不正確，無法核准';
    end if;

    for v_credit in
      select c.id,c.remaining_days,c.daily_hours_snapshot
      from public.annual_leave_credits c
      where c.staff_id = new.applicant_staff_id
        and new.leave_date between c.period_start and c.period_end
        and c.settlement_status = 'active'
        and c.remaining_days > 0
      order by c.period_end,c.period_start,c.created_at,c.id
      for update
    loop
      exit when v_need_days <= 0.0000005;

      v_take_days := least(v_need_days, v_credit.remaining_days);

      if v_take_days >= v_need_days - 0.0000005 then
        v_take_minutes := v_need_minutes;
      else
        v_take_minutes := greatest(
          1,
          round(new.minutes::numeric * (v_take_days / new.leave_days))::integer
        );
      end if;

      v_new_remaining_days := greatest(0, v_credit.remaining_days - v_take_days);

      update public.annual_leave_credits
      set remaining_days = v_new_remaining_days,
          remaining_minutes = case
            when daily_hours_snapshot is not null and daily_hours_snapshot > 0
              then round(v_new_remaining_days * daily_hours_snapshot * 60)::integer
            else remaining_minutes
          end,
          updated_at = now()
      where id = v_credit.id;

      insert into public.annual_leave_allocations(
        credit_id,request_id,allocation_date,minutes,days,is_active
      ) values (
        v_credit.id,new.id,new.leave_date,v_take_minutes,v_take_days,true
      );

      v_need_days := greatest(0, v_need_days - v_take_days);
      v_need_minutes := greatest(0, v_need_minutes - v_take_minutes);
    end loop;

    if v_need_days > 0.0000005 then
      raise exception '特休可用餘額不足，無法核准';
    end if;

  elsif old.status = 'approved' and new.status = 'voided' then
    for v_credit in
      select a.id as allocation_id,a.credit_id,a.minutes,a.days
      from public.annual_leave_allocations a
      where a.request_id = new.id
        and a.is_active = true
      for update
    loop
      update public.annual_leave_credits
      set remaining_days = least(granted_days, remaining_days + coalesce(v_credit.days,0)),
          remaining_minutes = case
            when daily_hours_snapshot is not null and daily_hours_snapshot > 0
              then round(
                least(granted_days, remaining_days + coalesce(v_credit.days,0))
                * daily_hours_snapshot * 60
              )::integer
            else remaining_minutes + v_credit.minutes
          end,
          updated_at = now()
      where id = v_credit.credit_id;

      update public.annual_leave_allocations
      set is_active = false,
          reversed_at = now()
      where id = v_credit.allocation_id;
    end loop;
  end if;

  return new;
end;
$function$


-- private.annual_leave_available_days
CREATE OR REPLACE FUNCTION private.annual_leave_available_days(p_staff_id uuid, p_leave_date date DEFAULT ((now() AT TIME ZONE 'Asia/Taipei'::text))::date, p_exclude_request_id uuid DEFAULT NULL::uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_current_staff uuid;
  v_allowed boolean;
  v_available numeric(10,6) := 0;
  v_pending numeric(10,6) := 0;
begin
  if (select auth.uid()) is null then return 0; end if;

  v_current_staff := private.current_staff_user_id();
  v_allowed := (p_staff_id = v_current_staff)
    or private.can_manage_annual_leave()
    or private.can_review_annual_leave();

  if not coalesce(v_allowed,false) then return 0; end if;

  select coalesce(sum(c.remaining_days),0)
    into v_available
  from public.annual_leave_credits c
  where c.staff_id = p_staff_id
    and p_leave_date between c.period_start and c.period_end
    and c.settlement_status = 'active';

  select coalesce(sum(r.leave_days),0)
    into v_pending
  from public.annual_leave_requests r
  where r.applicant_staff_id = p_staff_id
    and r.status = 'pending'
    and r.leave_days is not null
    and (p_exclude_request_id is null or r.id <> p_exclude_request_id)
    and exists (
      select 1
      from public.annual_leave_credits c
      where c.staff_id = p_staff_id
        and c.settlement_status = 'active'
        and p_leave_date between c.period_start and c.period_end
        and r.leave_date between c.period_start and c.period_end
    );

  return greatest(v_available - v_pending, 0);
end;
$function$


-- private.generate_annual_leave_credits
CREATE OR REPLACE FUNCTION private.generate_annual_leave_credits(p_as_of date DEFAULT ((now() AT TIME ZONE 'Asia/Taipei'::text))::date)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_staff record;
  v_period record;
  v_days numeric(10,6);
  v_daily_hours numeric(6,2);
  v_start date;
  v_end date;
  v_key text;
  v_label text;
  v_minutes integer;
  v_existing public.annual_leave_credits%rowtype;
  v_used_days numeric(10,6);
  v_remaining_days numeric(10,6);
  v_affected integer := 0;
begin
  update public.annual_leave_credits c
  set settlement_status = case
        when c.remaining_days > 0 then 'pending_settlement'
        else 'settled'
      end,
      updated_at = now()
  where c.period_end < p_as_of
    and c.settlement_status = 'active';

  for v_staff in
    select s.id,s.display_name,s.hire_date,s.agreed_daily_hours
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
    from private.staff_anniversary_period(v_staff.id,p_as_of)
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

    if v_start is null or v_end is null or v_days <= 0
       or p_as_of not between v_start and v_end then
      continue;
    end if;

    select private.staff_agreed_daily_hours_on(v_staff.id,v_start)
      into v_daily_hours;

    if v_daily_hours is null then
      select c.daily_hours_snapshot
        into v_daily_hours
      from public.annual_leave_credits c
      where c.staff_id=v_staff.id
        and c.entitlement_key=v_key
        and c.daily_hours_snapshot is not null
      order by c.created_at desc
      limit 1;
    end if;

    if v_daily_hours is null then
      select r.agreed_daily_hours
        into v_daily_hours
      from public.staff_payroll_rates r
      where r.staff_id=v_staff.id
        and r.effective_from<=v_start
      order by r.effective_from desc,r.created_at desc
      limit 1;
    end if;

    v_daily_hours := coalesce(v_daily_hours,v_staff.agreed_daily_hours);

    if v_daily_hours is null or v_daily_hours <= 0 or v_daily_hours > 8 then
      continue;
    end if;

    v_minutes := round(v_days * v_daily_hours * 60)::integer;

    select *
      into v_existing
    from public.annual_leave_credits c
    where c.staff_id=v_staff.id
      and c.entitlement_key=v_key
    limit 1;

    if found then
      if v_existing.generation_source='auto_weekly_anniversary'
         and v_existing.settlement_status='active' then
        v_used_days := greatest(
          0,
          coalesce(v_existing.granted_days,v_days)
          - coalesce(v_existing.remaining_days,v_days)
        );
        v_remaining_days := greatest(0,v_days-v_used_days);

        update public.annual_leave_credits
        set period_start=v_start,
            period_end=v_end,
            granted_days=v_days,
            remaining_days=v_remaining_days,
            granted_minutes=v_minutes,
            remaining_minutes=round(v_remaining_days*v_daily_hours*60)::integer,
            label=v_label,
            note='週年制自動產生：'
              || trim(to_char(v_days,'FM999990.######'))
              || '日；生效時約定每日'
              || trim(to_char(v_daily_hours,'FM999990.##')) || '小時',
            entitlement_days=v_days,
            daily_hours_snapshot=v_daily_hours,
            updated_at=now()
        where id=v_existing.id;

        v_affected := v_affected + 1;
      end if;
    else
      insert into public.annual_leave_credits(
        staff_id,period_start,period_end,
        granted_days,remaining_days,
        granted_minutes,remaining_minutes,
        label,note,created_by,created_by_name,
        entitlement_key,entitlement_days,daily_hours_snapshot,
        generation_source,settlement_status,auto_generated_at
      ) values (
        v_staff.id,v_start,v_end,
        v_days,v_days,
        v_minutes,v_minutes,
        v_label,
        '週年制自動產生：'
          || trim(to_char(v_days,'FM999990.######'))
          || '日；生效時約定每日'
          || trim(to_char(v_daily_hours,'FM999990.##')) || '小時',
        null,'系統自動產生',
        v_key,v_days,v_daily_hours,
        'auto_weekly_anniversary','active',now()
      );

      v_affected := v_affected + 1;
    end if;
  end loop;

  return v_affected;
end;
$function$


-- private.resolve_annual_leave_expiry_core
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
    update public.annual_leave_credits
    set remaining_days=0,
        remaining_minutes=0,
        settlement_status='settled',
        updated_at=now()
    where id=v_credit.id;

    insert into public.annual_leave_settlement_events(
      credit_id,staff_id,action,days,minutes,agreement_date,note,
      processed_by,processed_by_name,carryover_credit_id
    ) values (
      v_credit.id,v_credit.staff_id,'cash_settlement',v_days,v_minutes,null,
      nullif(trim(coalesce(p_note,'')),''),
      v_uid,v_name,null
    );

    return jsonb_build_object(
      'action','cash_settlement',
      'days',v_days,
      'minutes',v_minutes,
      'credit_id',v_credit.id
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
$function$


-- private.validate_annual_leave_request
CREATE OR REPLACE FUNCTION private.validate_annual_leave_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_expected integer;
  v_available numeric(10,6);
  v_hours numeric(4,2);
  v_chargeable_minutes numeric;
begin
  if new.end_time <= new.start_time then
    raise exception '特休結束時間須晚於開始時間';
  end if;

  if extract(minute from new.start_time)::integer not in (0,30)
     or extract(minute from new.end_time)::integer not in (0,30)
     or extract(second from new.start_time)::integer <> 0
     or extract(second from new.end_time)::integer <> 0 then
    raise exception '特休時間須以30分鐘為間隔';
  end if;

  v_expected := (extract(epoch from (new.end_time - new.start_time)) / 60)::integer;
  if new.minutes <> v_expected then
    raise exception '特休分鐘數與起訖時間不一致';
  end if;

  select private.staff_agreed_daily_hours_on(new.applicant_staff_id, new.leave_date)
    into v_hours;

  if v_hours is null then
    select s.agreed_daily_hours
      into v_hours
    from public.staff_users s
    where s.id = new.applicant_staff_id
      and s.is_active = true;
  end if;

  if v_hours is not null and v_hours > 0 and v_hours <= 8 then
    v_chargeable_minutes := least(new.minutes::numeric, v_hours * 60);
    new.work_hours_snapshot := v_hours;
    new.leave_days := round(v_chargeable_minutes / (v_hours * 60), 6);
  elsif new.status in ('pending','approved') then
    raise exception '此員工在特休日期尚未設定有效的約定每日工時';
  else
    new.work_hours_snapshot := null;
    new.leave_days := null;
  end if;

  if new.status in ('pending','approved') then
    if exists (
      select 1
      from public.annual_leave_requests r
      where r.applicant_staff_id = new.applicant_staff_id
        and r.leave_date = new.leave_date
        and r.status in ('pending','approved')
        and r.id <> new.id
        and new.start_time < r.end_time
        and new.end_time > r.start_time
    ) then
      raise exception '同一時段已有特休申請';
    end if;

    if exists (
      select 1
      from public.comp_leave_usages r
      where r.applicant_staff_id = new.applicant_staff_id
        and r.leave_date = new.leave_date
        and r.status in ('pending','approved')
        and new.start_time < r.end_time
        and new.end_time > r.start_time
    ) then
      raise exception '同一時段已有換休申請';
    end if;

    v_available := private.annual_leave_available_days(
      new.applicant_staff_id,
      new.leave_date,
      new.id
    );

    if coalesce(new.leave_days,0) > v_available then
      raise exception '特休可用餘額不足';
    end if;
  end if;

  return new;
end;
$function$


revoke all on function private.annual_leave_available_days(uuid,date,uuid) from public;
revoke all on function private.annual_leave_available_days(uuid,date,uuid) from anon;
revoke all on function private.annual_leave_available_days(uuid,date,uuid) from authenticated;

-- Existing annual_leave_requests_validate and annual_leave_requests_allocate triggers
-- continue to call the replaced validation/allocation functions.

select private.generate_annual_leave_credits();
