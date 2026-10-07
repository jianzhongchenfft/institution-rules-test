-- Work schedule timeline V1
-- Applied to V5.2 test database on 2026-10-08.
-- Normal work periods are effective-dated. Annual leave excludes break time.

alter table public.staff_work_hours_history
  add column if not exists work_start_time time without time zone,
  add column if not exists work_end_time time without time zone,
  add column if not exists break_start_time time without time zone,
  add column if not exists break_end_time time without time zone;

alter table public.staff_work_hours_history
  drop constraint if exists staff_work_hours_history_schedule_check;
alter table public.staff_work_hours_history
  add constraint staff_work_hours_history_schedule_check
  check (
    (
      work_start_time is null and work_end_time is null
      and break_start_time is null and break_end_time is null
    )
    or
    (
      work_start_time is not null and work_end_time is not null
      and work_start_time < work_end_time
      and (
        (break_start_time is null and break_end_time is null)
        or
        (
          break_start_time is not null and break_end_time is not null
          and work_start_time < break_start_time
          and break_start_time < break_end_time
          and break_end_time < work_end_time
        )
      )
    )
  );

alter table public.annual_leave_requests
  add column if not exists charge_minutes integer;

alter table public.annual_leave_requests
  drop constraint if exists annual_leave_requests_charge_minutes_check;
alter table public.annual_leave_requests
  add constraint annual_leave_requests_charge_minutes_check
  check (charge_minutes is null or charge_minutes > 0);

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
  if old.status<>'approved' and new.status='approved' then
    v_need_days := new.leave_days;
    v_need_minutes := coalesce(new.charge_minutes,new.minutes);

    if v_need_days is null or v_need_days<=0 then
      raise exception '特休扣抵天數不正確，無法核准';
    end if;

    for v_credit in
      select c.id,c.remaining_days,c.daily_hours_snapshot
      from public.annual_leave_credits c
      where c.staff_id=new.applicant_staff_id
        and new.leave_date between c.period_start and c.period_end
        and c.settlement_status='active'
        and c.remaining_days>0
      order by c.period_end,c.period_start,c.created_at,c.id
      for update
    loop
      exit when v_need_days<=0.0000005;

      v_take_days := least(v_need_days,v_credit.remaining_days);

      if v_take_days>=v_need_days-0.0000005 then
        v_take_minutes := v_need_minutes;
      else
        v_take_minutes := greatest(
          1,
          round(coalesce(new.charge_minutes,new.minutes)::numeric
            * (v_take_days/new.leave_days))::integer
        );
      end if;

      v_new_remaining_days := greatest(0,v_credit.remaining_days-v_take_days);

      update public.annual_leave_credits
      set remaining_days=v_new_remaining_days,
          remaining_minutes=case
            when daily_hours_snapshot is not null and daily_hours_snapshot>0
              then round(v_new_remaining_days*daily_hours_snapshot*60)::integer
            else remaining_minutes
          end,
          updated_at=now()
      where id=v_credit.id;

      insert into public.annual_leave_allocations(
        credit_id,request_id,allocation_date,minutes,days,is_active
      ) values (
        v_credit.id,new.id,new.leave_date,v_take_minutes,v_take_days,true
      );

      v_need_days := greatest(0,v_need_days-v_take_days);
      v_need_minutes := greatest(0,v_need_minutes-v_take_minutes);
    end loop;

    if v_need_days>0.0000005 then
      raise exception '特休可用餘額不足，無法核准';
    end if;

  elsif old.status='approved' and new.status='voided' then
    for v_credit in
      select a.id as allocation_id,a.credit_id,a.minutes,a.days
      from public.annual_leave_allocations a
      where a.request_id=new.id
        and a.is_active=true
      for update
    loop
      update public.annual_leave_credits
      set remaining_days=least(
            granted_days,
            remaining_days+coalesce(v_credit.days,0)
          ),
          remaining_minutes=case
            when daily_hours_snapshot is not null and daily_hours_snapshot>0
              then round(
                least(
                  granted_days,
                  remaining_days+coalesce(v_credit.days,0)
                )*daily_hours_snapshot*60
              )::integer
            else remaining_minutes+v_credit.minutes
          end,
          updated_at=now()
      where id=v_credit.credit_id;

      update public.annual_leave_allocations
      set is_active=false,
          reversed_at=now()
      where id=v_credit.allocation_id;
    end loop;
  end if;

  return new;
end;
$function$


-- private.annual_leave_charge_minutes
CREATE OR REPLACE FUNCTION private.annual_leave_charge_minutes(p_staff_id uuid, p_leave_date date, p_start_time time without time zone, p_end_time time without time zone)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_schedule record;
  v_effective_hours numeric;
  v_minutes numeric := 0;
  v_start time without time zone;
  v_end time without time zone;
begin
  if p_staff_id is null
     or p_leave_date is null
     or p_start_time is null
     or p_end_time is null
     or p_end_time <= p_start_time then
    return null;
  end if;

  select *
    into v_schedule
  from private.staff_work_schedule_on(p_staff_id,p_leave_date)
  limit 1;

  if v_schedule.work_start_time is null or v_schedule.work_end_time is null then
    return null;
  end if;

  select private.staff_agreed_daily_hours_on(p_staff_id,p_leave_date)
    into v_effective_hours;

  if v_effective_hours is null then
    select s.agreed_daily_hours
      into v_effective_hours
    from public.staff_users s
    where s.id=p_staff_id
      and s.is_active=true;
  end if;

  if v_effective_hours is null
     or abs(v_effective_hours - v_schedule.agreed_daily_hours) > 0.0001 then
    return null;
  end if;

  if v_schedule.break_start_time is null then
    v_start := greatest(p_start_time,v_schedule.work_start_time);
    v_end := least(p_end_time,v_schedule.work_end_time);
    if v_end > v_start then
      v_minutes := extract(epoch from (v_end-v_start))/60;
    end if;
  else
    v_start := greatest(p_start_time,v_schedule.work_start_time);
    v_end := least(p_end_time,v_schedule.break_start_time);
    if v_end > v_start then
      v_minutes := v_minutes + extract(epoch from (v_end-v_start))/60;
    end if;

    v_start := greatest(p_start_time,v_schedule.break_end_time);
    v_end := least(p_end_time,v_schedule.work_end_time);
    if v_end > v_start then
      v_minutes := v_minutes + extract(epoch from (v_end-v_start))/60;
    end if;
  end if;

  return greatest(0,round(v_minutes)::integer);
end;
$function$


-- private.request_leave_cancellation_core
CREATE OR REPLACE FUNCTION private.request_leave_cancellation_core(p_source_type text, p_source_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_staff_id uuid := private.current_staff_user_id();
  v_reason text := btrim(coalesce(p_reason,''));
  v_name text;
  v_leave_date date;
  v_minutes integer;
  v_status text;
  v_id uuid;
  v_today date := ((now() at time zone 'Asia/Taipei')::date);
begin
  if v_uid is null or v_staff_id is null then
    raise exception '尚未登入。' using errcode='42501';
  end if;
  if v_reason='' then
    raise exception '請填寫銷假原因。' using errcode='P0001';
  end if;
  if p_source_type not in ('comp_leave','annual_leave') then
    raise exception '不支援的銷假類型。' using errcode='P0001';
  end if;

  if p_source_type='comp_leave' then
    select applicant_name,leave_date,minutes,status
      into v_name,v_leave_date,v_minutes,v_status
    from public.comp_leave_usages
    where id=p_source_id and applicant_staff_id=v_staff_id
    for update;
  else
    select applicant_name,leave_date,coalesce(charge_minutes,minutes),status
      into v_name,v_leave_date,v_minutes,v_status
    from public.annual_leave_requests
    where id=p_source_id and applicant_staff_id=v_staff_id
    for update;
  end if;

  if v_name is null then
    raise exception '找不到可申請銷假的紀錄。' using errcode='P0001';
  end if;
  if v_status<>'approved' then
    raise exception '只有已核准的假別可以申請銷假。' using errcode='P0001';
  end if;
  if v_leave_date<=v_today then
    raise exception '休假日已到或已過，請聯繫管理者處理。' using errcode='P0001';
  end if;
  if exists(
    select 1
    from public.leave_cancellation_requests
    where source_type=p_source_type
      and source_id=p_source_id
      and status='pending'
  ) then
    raise exception '此筆假別已有待審核的銷假申請。' using errcode='P0001';
  end if;

  insert into public.leave_cancellation_requests(
    source_type,source_id,applicant_staff_id,applicant_name,
    leave_date,minutes,reason,status,requested_by,requested_at,created_at,updated_at
  ) values (
    p_source_type,p_source_id,v_staff_id,v_name,
    v_leave_date,v_minutes,v_reason,'pending',v_uid,now(),now(),now()
  )
  returning id into v_id;

  return jsonb_build_object('id',v_id,'status','pending');
end;
$function$


-- private.staff_work_schedule_on
CREATE OR REPLACE FUNCTION private.staff_work_schedule_on(p_staff_id uuid, p_date date)
 RETURNS TABLE(effective_from date, agreed_daily_hours numeric, work_start_time time without time zone, work_end_time time without time zone, break_start_time time without time zone, break_end_time time without time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select
    h.effective_from,
    h.agreed_daily_hours,
    h.work_start_time,
    h.work_end_time,
    h.break_start_time,
    h.break_end_time
  from public.staff_work_hours_history h
  where h.staff_id = p_staff_id
    and h.effective_from <= p_date
    and h.work_start_time is not null
    and h.work_end_time is not null
  order by h.effective_from desc, h.created_at desc
  limit 1;
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
  v_charge_minutes integer;
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

  v_expected := (extract(epoch from (new.end_time-new.start_time))/60)::integer;
  if new.minutes <> v_expected then
    raise exception '特休分鐘數與起訖時間不一致';
  end if;

  select private.staff_agreed_daily_hours_on(new.applicant_staff_id,new.leave_date)
    into v_hours;

  if v_hours is null then
    select s.agreed_daily_hours
      into v_hours
    from public.staff_users s
    where s.id=new.applicant_staff_id
      and s.is_active=true;
  end if;

  select private.annual_leave_charge_minutes(
    new.applicant_staff_id,new.leave_date,new.start_time,new.end_time
  ) into v_charge_minutes;

  if v_hours is not null
     and v_hours > 0
     and v_hours <= 8
     and v_charge_minutes is not null
     and v_charge_minutes > 0 then
    new.work_hours_snapshot := v_hours;
    new.charge_minutes := v_charge_minutes;
    new.leave_days := round(
      least(v_charge_minutes::numeric,v_hours*60)/(v_hours*60),
      6
    );
  elsif new.status in ('pending','approved') then
    if v_charge_minutes = 0 then
      raise exception '所選特休時段未落在正常工作時間內';
    else
      raise exception '此日期尚未設定可用的正常工作時段，請先至人員管理補齊工時時間軸';
    end if;
  else
    new.work_hours_snapshot := null;
    new.charge_minutes := null;
    new.leave_days := null;
  end if;

  if new.status in ('pending','approved') then
    if exists (
      select 1
      from public.annual_leave_requests r
      where r.applicant_staff_id=new.applicant_staff_id
        and r.leave_date=new.leave_date
        and r.status in ('pending','approved')
        and r.id<>new.id
        and new.start_time<r.end_time
        and new.end_time>r.start_time
    ) then
      raise exception '同一時段已有特休申請';
    end if;

    if exists (
      select 1
      from public.comp_leave_usages r
      where r.applicant_staff_id=new.applicant_staff_id
        and r.leave_date=new.leave_date
        and r.status in ('pending','approved')
        and new.start_time<r.end_time
        and new.end_time>r.start_time
    ) then
      raise exception '同一時段已有換休申請';
    end if;

    v_available := private.annual_leave_available_days(
      new.applicant_staff_id,new.leave_date,new.id
    );

    if coalesce(new.leave_days,0)>v_available then
      raise exception '特休可用餘額不足';
    end if;
  end if;

  return new;
end;
$function$


-- public.save_staff_work_schedule_timeline
CREATE OR REPLACE FUNCTION public.save_staff_work_schedule_timeline(p_staff_id uuid, p_effective_from date, p_agreed_daily_hours numeric, p_work_start_time time without time zone, p_work_end_time time without time zone, p_break_start_time time without time zone DEFAULT NULL::time without time zone, p_break_end_time time without time zone DEFAULT NULL::time without time zone, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_actor_name text;
  v_history_id uuid;
  v_net_minutes numeric;
  v_break_minutes numeric := 0;
  v_current_hours numeric(4,2);
  v_payroll_hours numeric(4,2);
  v_monthly_wage_base numeric;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode='42501';
  end if;

  if not coalesce(private.can_review_overtime(),false) then
    raise exception 'insufficient permission' using errcode='42501';
  end if;

  if p_staff_id is null
     or p_effective_from is null
     or p_agreed_daily_hours is null
     or p_work_start_time is null
     or p_work_end_time is null then
    raise exception 'staff, effective date, daily hours and work times are required'
      using errcode='22023';
  end if;

  if p_agreed_daily_hours <= 0 or p_agreed_daily_hours > 8 then
    raise exception 'agreed_daily_hours must be greater than zero and at most 8'
      using errcode='22023';
  end if;

  if p_work_end_time <= p_work_start_time then
    raise exception 'work end time must be later than work start time'
      using errcode='22023';
  end if;

  if (p_break_start_time is null) <> (p_break_end_time is null) then
    raise exception 'break start and end must both be filled or both be empty'
      using errcode='22023';
  end if;

  if p_break_start_time is not null then
    if not (
      p_work_start_time < p_break_start_time
      and p_break_start_time < p_break_end_time
      and p_break_end_time < p_work_end_time
    ) then
      raise exception 'break time must fall inside the work period'
        using errcode='22023';
    end if;
    v_break_minutes := extract(epoch from (p_break_end_time-p_break_start_time))/60;
  end if;

  v_net_minutes :=
    extract(epoch from (p_work_end_time-p_work_start_time))/60
    - v_break_minutes;

  if abs(v_net_minutes-(p_agreed_daily_hours*60)) > 0.01 then
    raise exception 'daily hours do not match work period minus break (% minutes vs % minutes)',
      v_net_minutes,p_agreed_daily_hours*60
      using errcode='22023';
  end if;

  if not exists (
    select 1
    from public.staff_users s
    where s.id=p_staff_id and s.is_active=true
  ) then
    raise exception 'active staff not found' using errcode='P0002';
  end if;

  v_actor_name := private.current_staff_user_name();
  if v_actor_name is null or btrim(v_actor_name)='' then
    raise exception 'current staff profile not found' using errcode='42501';
  end if;

  insert into public.staff_work_hours_history(
    staff_id,effective_from,agreed_daily_hours,
    work_start_time,work_end_time,break_start_time,break_end_time,
    note,created_by,created_by_name
  ) values (
    p_staff_id,p_effective_from,p_agreed_daily_hours,
    p_work_start_time,p_work_end_time,p_break_start_time,p_break_end_time,
    nullif(btrim(coalesce(p_note,'')),''),
    v_uid,v_actor_name
  )
  returning id into v_history_id;

  select h.agreed_daily_hours
    into v_current_hours
  from public.staff_work_hours_history h
  where h.staff_id=p_staff_id
    and h.effective_from<=((now() at time zone 'Asia/Taipei')::date)
  order by h.effective_from desc,h.created_at desc
  limit 1;

  update public.staff_users
  set agreed_daily_hours=coalesce(v_current_hours,p_agreed_daily_hours),
      updated_at=now()
  where id=p_staff_id and is_active=true;

  select r.agreed_daily_hours,r.monthly_wage_base
    into v_payroll_hours,v_monthly_wage_base
  from public.staff_payroll_rates r
  where r.staff_id=p_staff_id
    and r.effective_from<=p_effective_from
  order by r.effective_from desc,r.created_at desc
  limit 1;

  if v_monthly_wage_base is not null
     and (v_payroll_hours is null or abs(v_payroll_hours-p_agreed_daily_hours)>0.0001) then
    insert into public.staff_payroll_rates(
      staff_id,effective_from,monthly_wage_base,agreed_daily_hours,
      note,created_by,created_by_name
    ) values (
      p_staff_id,p_effective_from,v_monthly_wage_base,p_agreed_daily_hours,
      '正常工作時段同步'
        || case
          when nullif(btrim(coalesce(p_note,'')),'') is not null
            then '：'||nullif(btrim(coalesce(p_note,'')),'')
          else ''
        end,
      v_uid,v_actor_name
    );
  end if;

  return v_history_id;
end;
$function$


revoke all on function private.staff_work_schedule_on(uuid,date) from public;
revoke all on function private.staff_work_schedule_on(uuid,date) from anon;
revoke all on function private.staff_work_schedule_on(uuid,date) from authenticated;

revoke all on function private.annual_leave_charge_minutes(uuid,date,time,time) from public;
revoke all on function private.annual_leave_charge_minutes(uuid,date,time,time) from anon;
revoke all on function private.annual_leave_charge_minutes(uuid,date,time,time) from authenticated;

revoke all on function public.save_staff_work_schedule_timeline(
  uuid,date,numeric,time,time,time,time,text
) from public;
revoke all on function public.save_staff_work_schedule_timeline(
  uuid,date,numeric,time,time,time,time,text
) from anon;
grant execute on function public.save_staff_work_schedule_timeline(
  uuid,date,numeric,time,time,time,time,text
) to authenticated;

-- Current schedules supplied for the V5.2 test environment.
with actor as (
  select id from auth.users
  where lower(email)=lower('greenheart231@gmail.com')
  limit 1
),
src(display_name,daily_hours,work_start,work_end,break_start,break_end,note) as (
  values
    ('陳妍蓁',6.00::numeric,'09:00'::time,'16:00'::time,'12:00'::time,'13:00'::time,'目前班型：09:00-16:00，午休12:00-13:00'),
    ('廖家玟',7.00::numeric,'09:00'::time,'17:00'::time,'12:00'::time,'13:00'::time,'目前班型：09:00-17:00，午休12:00-13:00'),
    ('邱依嫻',7.00::numeric,'09:00'::time,'17:00'::time,'12:00'::time,'13:00'::time,'目前班型：09:00-17:00，午休12:00-13:00'),
    ('陳建中',7.00::numeric,'09:00'::time,'17:00'::time,'12:00'::time,'13:00'::time,'目前班型：09:00-17:00，午休12:00-13:00')
)
insert into public.staff_work_hours_history(
  staff_id,effective_from,agreed_daily_hours,
  work_start_time,work_end_time,break_start_time,break_end_time,
  note,created_by,created_by_name
)
select
  s.id,'2026-10-08'::date,src.daily_hours,
  src.work_start,src.work_end,src.break_start,src.break_end,
  src.note,actor.id,'陳建中'
from src
join public.staff_users s on s.display_name=src.display_name
cross join actor
where s.is_active=true
  and not exists (
    select 1 from public.staff_work_hours_history h
    where h.staff_id=s.id
      and h.effective_from='2026-10-08'::date
      and h.agreed_daily_hours=src.daily_hours
      and h.work_start_time=src.work_start
      and h.work_end_time=src.work_end
      and h.break_start_time=src.break_start
      and h.break_end_time=src.break_end
  );
