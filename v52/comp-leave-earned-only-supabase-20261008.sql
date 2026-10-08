-- V5.2 換休額度：只有已實際取得的額度可支應換休
-- 取得日不得晚於核准當下；未來換休日仍須確認額度尚未到期。
-- 前端預覽與資料庫實際 allocation 使用同一原則。

CREATE OR REPLACE FUNCTION private.allocate_comp_leave_debit(p_staff_id uuid, p_debit_date date, p_minutes integer, p_debit_type text, p_debit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_need integer := p_minutes;
  v_take integer;
  v_today date := ((now() at time zone 'Asia/Taipei')::date);
  v_earned_cutoff date;
  r record;
begin
  if coalesce(p_minutes,0) <= 0 then return; end if;
  if p_debit_type not in ('leave_usage','payroll_correction') then
    raise exception '不支援的換休扣抵類型';
  end if;

  if exists(
    select 1
    from public.comp_leave_allocations a
    where a.debit_type=p_debit_type and a.debit_id=p_debit_id
  ) then
    return;
  end if;

  -- 未來才取得的換休不得提前支應。
  -- 若補登過去的換休，取得日也不得晚於實際換休日。
  v_earned_cutoff := least(v_today,p_debit_date);

  for r in
    select c.id,c.remaining_minutes
    from public.comp_leave_credits c
    where c.staff_id=p_staff_id
      and c.earned_date <= v_earned_cutoff
      and c.remaining_minutes > 0
      and (c.expires_on is null or c.expires_on >= p_debit_date)
    order by
      case when c.source_type='overtime_request' and exists(
        select 1
        from public.overtime_requests o
        where o.id=c.source_id and o.request_type='holiday_visit_comp'
      ) then 1 else 0 end,
      c.expires_on nulls last,
      c.earned_date,c.created_at,c.id
    for update
  loop
    exit when v_need <= 0;
    v_take := least(v_need,r.remaining_minutes);

    update public.comp_leave_credits
       set remaining_minutes=remaining_minutes-v_take,
           updated_at=now()
     where id=r.id;

    insert into public.comp_leave_allocations(
      credit_id,debit_type,debit_id,allocation_date,minutes
    ) values (
      r.id,p_debit_type,p_debit_id,p_debit_date,v_take
    );

    v_need := v_need-v_take;
  end loop;

  if v_need > 0 then
    raise exception '目前已取得且於換休日仍有效的換休時數不足；未來尚未取得的加班／換休額度不可提前使用。';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION private.comp_leave_available_minutes(p_staff_id uuid, p_exclude_usage_id uuid DEFAULT NULL::uuid, p_as_of date DEFAULT ((now() AT TIME ZONE 'Asia/Taipei'::text))::date)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_current_staff uuid;
  v_can_review boolean;
  v_available integer := 0;
  v_pending integer := 0;
  v_today date := ((now() at time zone 'Asia/Taipei')::date);
  v_usage_date date := coalesce(p_as_of,v_today);
  v_earned_cutoff date;
begin
  if (select auth.uid()) is null then return 0; end if;

  v_current_staff:=private.current_staff_user_id();
  v_can_review:=private.can_review_overtime();

  if p_staff_id is distinct from v_current_staff
     and not coalesce(v_can_review,false) then
    return 0;
  end if;

  v_earned_cutoff := least(v_today,v_usage_date);

  select coalesce(sum(c.remaining_minutes),0)::integer
    into v_available
  from public.comp_leave_credits c
  where c.staff_id=p_staff_id
    and c.earned_date<=v_earned_cutoff
    and c.remaining_minutes>0
    and (c.expires_on is null or c.expires_on>=v_usage_date);

  select coalesce(sum(u.minutes),0)::integer
    into v_pending
  from public.comp_leave_usages u
  where u.applicant_staff_id=p_staff_id
    and u.status='pending'
    and (p_exclude_usage_id is null or u.id<>p_exclude_usage_id);

  return greatest(v_available-v_pending,0);
end;
$function$;

CREATE OR REPLACE FUNCTION private.payroll_comp_leave_used_preview_core(p_settlement_id uuid, p_staff_id uuid, p_leave_date date, p_start_time time without time zone, p_end_time time without time zone, p_direction integer)
 RETURNS TABLE(correction_minutes integer, available_minutes integer, related_source_type text, related_source_id uuid, related_source_label text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_month date;
  v_start integer;
  v_end integer;
  v_minutes integer;
  v_overlap integer;
  v_source_type text;
  v_source_id uuid;
  v_source_label text;
  v_source_count integer;
  v_available integer:=0;
  v_today date := ((now() at time zone 'Asia/Taipei')::date);
  v_earned_cutoff date;
begin
  if (select auth.uid()) is not null and not private.can_review_overtime() then
    raise exception '目前帳號沒有薪資更正權限。' using errcode='42501';
  end if;
  if p_direction not in (-1,1) then
    raise exception '更正方向錯誤。' using errcode='P0001';
  end if;
  if p_leave_date is null or p_start_time is null or p_end_time is null then
    raise exception '請填寫實際換休使用日期與起訖時間。' using errcode='P0001';
  end if;
  if extract(second from p_start_time)<>0 or extract(second from p_end_time)<>0
     or mod(extract(minute from p_start_time)::integer,30)<>0
     or mod(extract(minute from p_end_time)::integer,30)<>0 then
    raise exception '換休使用更正時間請以30分鐘為間隔。' using errcode='P0001';
  end if;

  v_start:=extract(hour from p_start_time)::integer*60+extract(minute from p_start_time)::integer;
  v_end:=extract(hour from p_end_time)::integer*60+extract(minute from p_end_time)::integer;
  if v_end=0 and v_start>0 then v_end:=1440; end if;
  if v_end<=v_start then
    raise exception '跨午夜換休使用更正不可用一筆建立，請分成兩筆。' using errcode='P0001';
  end if;
  v_minutes:=v_end-v_start;
  if mod(v_minutes,30)<>0 then
    raise exception '換休使用更正時數須為30分鐘的倍數。' using errcode='P0001';
  end if;

  select s.settlement_month
    into v_month
  from public.payroll_month_settlements s
  where s.id=p_settlement_id;

  if v_month is null then
    raise exception '找不到月結資料。' using errcode='P0001';
  end if;

  if date_trunc('month',p_leave_date)::date<>v_month then
    raise exception '換休使用日期必須屬於該月結月份。' using errcode='P0001';
  end if;

  if p_direction>0 then
    select count(*)
      into v_overlap
    from (
      select u.id
      from public.comp_leave_usages u
      where u.applicant_staff_id=p_staff_id
        and u.leave_date=p_leave_date
        and u.status='approved'
        and (extract(hour from u.start_time)::integer*60+extract(minute from u.start_time)::integer) < v_end
        and (
          case
            when u.end_time=time '00:00' and u.start_time>time '00:00' then 1440
            else extract(hour from u.end_time)::integer*60+extract(minute from u.end_time)::integer
          end
        ) > v_start
        and not exists (
          select 1
          from public.payroll_settlement_corrections r
          where r.adjustment_type='comp_leave_used'
            and r.adjustment_minutes<0
            and r.related_source_type='leave_usage'
            and r.related_source_id=u.id
        )

      union all

      select c.id
      from public.payroll_settlement_corrections c
      where c.staff_id=p_staff_id
        and c.adjustment_type='comp_leave_used'
        and c.adjustment_minutes>0
        and c.work_date=p_leave_date
        and c.start_time is not null
        and c.end_time is not null
        and (extract(hour from c.start_time)::integer*60+extract(minute from c.start_time)::integer) < v_end
        and (
          case
            when c.end_time=time '00:00' and c.start_time>time '00:00' then 1440
            else extract(hour from c.end_time)::integer*60+extract(minute from c.end_time)::integer
          end
        ) > v_start
        and not exists (
          select 1
          from public.payroll_settlement_corrections r
          where r.adjustment_type='comp_leave_used'
            and r.adjustment_minutes<0
            and r.related_source_type='payroll_correction'
            and r.related_source_id=c.id
        )
    ) q;

    if v_overlap>0 then
      raise exception '此換休使用更正時段與既有已認列換休使用重疊。' using errcode='P0001';
    end if;

    v_earned_cutoff := least(v_today,p_leave_date);

    select coalesce(sum(c.remaining_minutes),0)::integer
      into v_available
    from public.comp_leave_credits c
    where c.staff_id=p_staff_id
      and c.earned_date<=v_earned_cutoff
      and c.remaining_minutes>0
      and (c.expires_on is null or c.expires_on>=p_leave_date);

    if v_available<v_minutes then
      raise exception '目前已取得且於換休日仍有效的換休時數不足，無法建立更正。' using errcode='P0001';
    end if;

    return query
    select v_minutes,v_available,null::text,null::uuid,null::text;
    return;
  end if;

  with candidates as (
    select
      'leave_usage'::text source_type,
      u.id source_id,
      (
        '原換休使用 '
        ||to_char(u.leave_date,'YYYY-MM-DD')
        ||' '
        ||to_char(u.start_time,'HH24:MI')
        ||'–'
        ||case
            when u.end_time=time '00:00' and u.start_time>time '00:00' then '24:00'
            else to_char(u.end_time,'HH24:MI')
          end
      )::text source_label
    from public.comp_leave_usages u
    where u.applicant_staff_id=p_staff_id
      and u.leave_date=p_leave_date
      and u.status='approved'
      and u.start_time=p_start_time
      and u.end_time=p_end_time
      and u.minutes=v_minutes
      and not exists (
        select 1
        from public.payroll_settlement_corrections r
        where r.adjustment_type='comp_leave_used'
          and r.adjustment_minutes<0
          and r.related_source_type='leave_usage'
          and r.related_source_id=u.id
      )

    union all

    select
      'payroll_correction'::text,
      c.id,
      (
        '月結後補登換休使用 '
        ||to_char(c.work_date,'YYYY-MM-DD')
        ||' '
        ||to_char(c.start_time,'HH24:MI')
        ||'–'
        ||case
            when c.end_time=time '00:00' and c.start_time>time '00:00' then '24:00'
            else to_char(c.end_time,'HH24:MI')
          end
      )::text
    from public.payroll_settlement_corrections c
    where c.staff_id=p_staff_id
      and c.adjustment_type='comp_leave_used'
      and c.adjustment_minutes>0
      and c.work_date=p_leave_date
      and c.start_time=p_start_time
      and c.end_time=p_end_time
      and c.adjustment_minutes=v_minutes
      and not exists (
        select 1
        from public.payroll_settlement_corrections r
        where r.adjustment_type='comp_leave_used'
          and r.adjustment_minutes<0
          and r.related_source_type='payroll_correction'
          and r.related_source_id=c.id
      )
  )
  select count(*)
    into v_source_count
  from candidates;

  if v_source_count=0 then
    raise exception '減少認列時，起訖時間必須完整對應一筆尚未更正的既有換休使用紀錄。若只需修正部分時數，請先整筆減少，再補登正確時段。' using errcode='P0001';
  elsif v_source_count>1 then
    raise exception '找到多筆相同換休使用紀錄，請先由系統管理員確認資料。' using errcode='P0001';
  end if;

  with candidates as (
    select
      'leave_usage'::text source_type,
      u.id source_id,
      (
        '原換休使用 '
        ||to_char(u.leave_date,'YYYY-MM-DD')
        ||' '
        ||to_char(u.start_time,'HH24:MI')
        ||'–'
        ||case
            when u.end_time=time '00:00' and u.start_time>time '00:00' then '24:00'
            else to_char(u.end_time,'HH24:MI')
          end
      )::text source_label
    from public.comp_leave_usages u
    where u.applicant_staff_id=p_staff_id
      and u.leave_date=p_leave_date
      and u.status='approved'
      and u.start_time=p_start_time
      and u.end_time=p_end_time
      and u.minutes=v_minutes
      and not exists (
        select 1
        from public.payroll_settlement_corrections r
        where r.adjustment_type='comp_leave_used'
          and r.adjustment_minutes<0
          and r.related_source_type='leave_usage'
          and r.related_source_id=u.id
      )

    union all

    select
      'payroll_correction'::text,
      c.id,
      (
        '月結後補登換休使用 '
        ||to_char(c.work_date,'YYYY-MM-DD')
        ||' '
        ||to_char(c.start_time,'HH24:MI')
        ||'–'
        ||case
            when c.end_time=time '00:00' and c.start_time>time '00:00' then '24:00'
            else to_char(c.end_time,'HH24:MI')
          end
      )::text
    from public.payroll_settlement_corrections c
    where c.staff_id=p_staff_id
      and c.adjustment_type='comp_leave_used'
      and c.adjustment_minutes>0
      and c.work_date=p_leave_date
      and c.start_time=p_start_time
      and c.end_time=p_end_time
      and c.adjustment_minutes=v_minutes
      and not exists (
        select 1
        from public.payroll_settlement_corrections r
        where r.adjustment_type='comp_leave_used'
          and r.adjustment_minutes<0
          and r.related_source_type='payroll_correction'
          and r.related_source_id=c.id
      )
  )
  select source_type,source_id,source_label
    into v_source_type,v_source_id,v_source_label
  from candidates
  limit 1;

  if not exists (
    select 1
    from public.comp_leave_allocations a
    where a.debit_type=v_source_type and a.debit_id=v_source_id
  ) then
    raise exception '此既有換休使用沒有可還原的原始扣抵來源，請由系統管理員處理。' using errcode='P0001';
  end if;

  return query
  select v_minutes,0,v_source_type,v_source_id,v_source_label;
end;
$function$;

CREATE OR REPLACE FUNCTION private.validate_comp_leave_usage_balance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_today date := ((now() at time zone 'Asia/Taipei')::date);
  v_earned_cutoff date;
  v_available integer := 0;
  v_pending integer := 0;
begin
  if new.status not in ('pending','approved') then
    return new;
  end if;

  if new.leave_date is null or coalesce(new.minutes,0)<=0 then
    return new;
  end if;

  v_earned_cutoff := least(v_today,new.leave_date);

  select coalesce(sum(c.remaining_minutes),0)::integer
    into v_available
  from public.comp_leave_credits c
  where c.staff_id=new.applicant_staff_id
    and c.earned_date<=v_earned_cutoff
    and c.remaining_minutes>0
    and (c.expires_on is null or c.expires_on>=new.leave_date);

  select coalesce(sum(u.minutes),0)::integer
    into v_pending
  from public.comp_leave_usages u
  where u.applicant_staff_id=new.applicant_staff_id
    and u.status='pending'
    and u.id<>new.id;

  if new.minutes > greatest(v_available-v_pending,0) then
    raise exception
      '目前已取得且於換休日仍有效的換休僅 % 分鐘，本次申請 % 分鐘；未來尚未取得的加班／換休額度不可提前使用。',
      greatest(v_available-v_pending,0),
      new.minutes
      using errcode='P0001';
  end if;

  return new;
end;
$function$;

drop trigger if exists comp_leave_usages_balance_guard
  on public.comp_leave_usages;

create trigger comp_leave_usages_balance_guard
before insert or update of status,leave_date,minutes
on public.comp_leave_usages
for each row
execute function private.validate_comp_leave_usage_balance();
