-- Work-hours timeline V1
-- Purpose:
-- 1) Keep staff_users.agreed_daily_hours as the current convenient value.
-- 2) Keep effective-dated work-hour history separately.
-- 3) Let annual leave resolve the hours that were effective on entitlement start.
-- 4) Keep payroll-rate changes synchronized into the same work-hour history.
--
-- Test-data corrections are intentionally NOT hard-coded in this schema file.

create table if not exists public.staff_work_hours_history (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff_users(id),
  effective_from date not null,
  agreed_daily_hours numeric(4,2) not null,
  note text,
  created_by uuid not null references auth.users(id),
  created_by_name text not null,
  created_at timestamptz not null default now(),
  constraint staff_work_hours_history_hours_check
    check (agreed_daily_hours > 0 and agreed_daily_hours <= 8)
);

create index if not exists staff_work_hours_history_staff_effective_idx
  on public.staff_work_hours_history(staff_id,effective_from desc,created_at desc);

alter table public.staff_work_hours_history enable row level security;
grant select, insert on table public.staff_work_hours_history to authenticated;

drop policy if exists staff_work_hours_read on public.staff_work_hours_history;
create policy staff_work_hours_read
on public.staff_work_hours_history
for select
to authenticated
using (
  (select private.can_review_overtime())
  or exists (
    select 1
    from public.staff_users s
    where s.id = staff_work_hours_history.staff_id
      and s.is_active = true
      and lower(s.email) = lower(coalesce((select auth.jwt()) ->> 'email',''))
  )
);

drop policy if exists staff_work_hours_insert on public.staff_work_hours_history;
create policy staff_work_hours_insert
on public.staff_work_hours_history
for insert
to authenticated
with check (
  (select private.can_review_overtime())
  and created_by = (select auth.uid())
  and created_by_name = (select private.current_staff_user_name())
  and exists (
    select 1
    from public.staff_users s
    where s.id = staff_work_hours_history.staff_id
      and s.is_active = true
  )
);

create or replace function private.staff_agreed_daily_hours_on(
  p_staff_id uuid,
  p_date date
)
returns numeric
language sql
stable
set search_path = ''
as $function$
  select h.agreed_daily_hours
  from public.staff_work_hours_history h
  where h.staff_id = p_staff_id
    and h.effective_from <= p_date
  order by h.effective_from desc, h.created_at desc
  limit 1;
$function$;

revoke all on function private.staff_agreed_daily_hours_on(uuid,date) from public;
revoke all on function private.staff_agreed_daily_hours_on(uuid,date) from anon;
revoke all on function private.staff_agreed_daily_hours_on(uuid,date) from authenticated;

-- Backfill known effective-dated hours from existing payroll snapshots.
insert into public.staff_work_hours_history(
  staff_id,effective_from,agreed_daily_hours,note,created_by,created_by_name,created_at
)
select
  r.staff_id,
  r.effective_from,
  r.agreed_daily_hours,
  '由既有薪資歷程匯入',
  r.created_by,
  r.created_by_name,
  r.created_at
from public.staff_payroll_rates r
where not exists (
  select 1
  from public.staff_work_hours_history h
  where h.staff_id=r.staff_id
    and h.effective_from=r.effective_from
    and h.agreed_daily_hours=r.agreed_daily_hours
    and h.created_at=r.created_at
);

create or replace function private.generate_annual_leave_credits(
  p_as_of date default ((now() at time zone 'Asia/Taipei'))::date
)
returns integer
language plpgsql
set search_path = ''
as $function$
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
  v_affected integer := 0;
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

    if v_start is null or v_end is null or v_days <= 0
       or p_as_of not between v_start and v_end then
      continue;
    end if;

    select private.staff_agreed_daily_hours_on(v_staff.id, v_start)
      into v_daily_hours;

    if v_daily_hours is null then
      select r.agreed_daily_hours
        into v_daily_hours
      from public.staff_payroll_rates r
      where r.staff_id = v_staff.id
        and r.effective_from <= v_start
      order by r.effective_from desc, r.created_at desc
      limit 1;
    end if;

    v_daily_hours := coalesce(v_daily_hours, v_staff.agreed_daily_hours);

    if v_daily_hours is null or v_daily_hours <= 0 or v_daily_hours > 8 then
      continue;
    end if;

    v_minutes := round(v_days * v_daily_hours * 60)::integer;

    insert into public.annual_leave_credits(
      staff_id,period_start,period_end,granted_minutes,remaining_minutes,label,note,
      created_by,created_by_name,entitlement_key,entitlement_days,daily_hours_snapshot,
      generation_source,settlement_status,auto_generated_at
    ) values (
      v_staff.id,v_start,v_end,v_minutes,v_minutes,v_label,
      '週年制自動產生：' || trim(to_char(v_days,'FM999990.##'))
        || '日 × 約定每日' || trim(to_char(v_daily_hours,'FM999990.##')) || '小時',
      null,'系統自動產生',v_key,v_days,v_daily_hours,
      'auto_weekly_anniversary','active',now()
    )
    on conflict (staff_id, entitlement_key) where entitlement_key is not null
    do update set
      granted_minutes = excluded.granted_minutes,
      remaining_minutes = greatest(
        0,
        excluded.granted_minutes
        - greatest(
            0,
            public.annual_leave_credits.granted_minutes
            - public.annual_leave_credits.remaining_minutes
          )
      ),
      label = excluded.label,
      note = excluded.note,
      entitlement_days = excluded.entitlement_days,
      daily_hours_snapshot = excluded.daily_hours_snapshot,
      generation_source = excluded.generation_source,
      updated_at = now()
    where public.annual_leave_credits.generation_source = 'auto_weekly_anniversary'
      and public.annual_leave_credits.settlement_status = 'active';

    if found then
      v_affected := v_affected + 1;
    end if;
  end loop;

  return v_affected;
end;
$function$;

create or replace function private.refresh_annual_leave_after_work_hours_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  perform private.generate_annual_leave_credits(
    (now() at time zone 'Asia/Taipei')::date
  );
  return new;
end;
$function$;

revoke all on function private.refresh_annual_leave_after_work_hours_change() from public;
revoke all on function private.refresh_annual_leave_after_work_hours_change() from anon;
revoke all on function private.refresh_annual_leave_after_work_hours_change() from authenticated;

drop trigger if exists trg_work_hours_annual_leave_refresh on public.staff_work_hours_history;
create trigger trg_work_hours_annual_leave_refresh
after insert on public.staff_work_hours_history
for each row
execute function private.refresh_annual_leave_after_work_hours_change();

create or replace function public.save_staff_work_hours_timeline(
  p_staff_id uuid,
  p_effective_from date,
  p_agreed_daily_hours numeric,
  p_note text default null
)
returns uuid
language plpgsql
set search_path = ''
as $function$
declare
  v_history_id uuid;
  v_actor_name text;
  v_current_hours numeric(4,2);
  v_monthly_wage_base numeric;
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not coalesce(private.can_review_overtime(), false) then
    raise exception 'insufficient permission' using errcode = '42501';
  end if;

  if p_staff_id is null or p_effective_from is null then
    raise exception 'staff_id and effective_from are required' using errcode = '22023';
  end if;

  if p_agreed_daily_hours is null or p_agreed_daily_hours <= 0 or p_agreed_daily_hours > 8 then
    raise exception 'agreed_daily_hours must be greater than zero and at most 8' using errcode = '22023';
  end if;

  v_actor_name := private.current_staff_user_name();

  if not exists (
    select 1 from public.staff_users s
    where s.id = p_staff_id and s.is_active = true
  ) then
    raise exception 'active staff not found' using errcode = 'P0002';
  end if;

  insert into public.staff_work_hours_history(
    staff_id,effective_from,agreed_daily_hours,note,created_by,created_by_name
  ) values (
    p_staff_id,p_effective_from,p_agreed_daily_hours,
    nullif(btrim(coalesce(p_note,'')),''),
    (select auth.uid()),v_actor_name
  )
  returning id into v_history_id;

  select h.agreed_daily_hours
    into v_current_hours
  from public.staff_work_hours_history h
  where h.staff_id = p_staff_id
    and h.effective_from <= ((now() at time zone 'Asia/Taipei')::date)
  order by h.effective_from desc,h.created_at desc
  limit 1;

  update public.staff_users
  set agreed_daily_hours = coalesce(v_current_hours,p_agreed_daily_hours),
      updated_at = now()
  where id = p_staff_id and is_active = true;

  -- Keep the payroll snapshot timeline usable without duplicating a salary-setting UI.
  select r.monthly_wage_base
    into v_monthly_wage_base
  from public.staff_payroll_rates r
  where r.staff_id = p_staff_id
    and r.effective_from <= p_effective_from
  order by r.effective_from desc,r.created_at desc
  limit 1;

  if v_monthly_wage_base is not null then
    insert into public.staff_payroll_rates(
      staff_id,effective_from,monthly_wage_base,agreed_daily_hours,note,created_by,created_by_name
    ) values (
      p_staff_id,p_effective_from,v_monthly_wage_base,p_agreed_daily_hours,
      '工時歷程同步' || case
        when nullif(btrim(coalesce(p_note,'')),'') is not null
          then '：' || nullif(btrim(coalesce(p_note,'')),'')
        else ''
      end,
      (select auth.uid()),v_actor_name
    );
  end if;

  return v_history_id;
end;
$function$;

revoke all on function public.save_staff_work_hours_timeline(uuid,date,numeric,text) from public;
revoke all on function public.save_staff_work_hours_timeline(uuid,date,numeric,text) from anon;
grant execute on function public.save_staff_work_hours_timeline(uuid,date,numeric,text) to authenticated;

-- Existing payroll-setting workflow also appends to the shared hours timeline.
create or replace function public.save_staff_payroll_rate(
  p_staff_id uuid,
  p_effective_from date,
  p_monthly_wage_base numeric,
  p_agreed_daily_hours numeric,
  p_note text default null
)
returns uuid
language plpgsql
set search_path = ''
as $function$
declare
  v_rate_id uuid;
  v_actor_name text;
  v_current_hours numeric(4,2);
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not coalesce(private.can_review_overtime(), false) then
    raise exception 'insufficient permission' using errcode = '42501';
  end if;

  if p_staff_id is null or p_effective_from is null then
    raise exception 'staff_id and effective_from are required' using errcode = '22023';
  end if;

  if p_monthly_wage_base is null or p_monthly_wage_base <= 0 then
    raise exception 'monthly_wage_base must be greater than zero' using errcode = '22023';
  end if;

  if p_agreed_daily_hours is null or p_agreed_daily_hours <= 0 or p_agreed_daily_hours > 8 then
    raise exception 'agreed_daily_hours must be greater than zero and at most 8' using errcode = '22023';
  end if;

  v_actor_name := private.current_staff_user_name();

  insert into public.staff_payroll_rates(
    staff_id,effective_from,monthly_wage_base,agreed_daily_hours,note,created_by,created_by_name
  ) values (
    p_staff_id,p_effective_from,p_monthly_wage_base,p_agreed_daily_hours,
    nullif(btrim(coalesce(p_note,'')),''),
    (select auth.uid()),v_actor_name
  )
  returning id into v_rate_id;

  insert into public.staff_work_hours_history(
    staff_id,effective_from,agreed_daily_hours,note,created_by,created_by_name
  ) values (
    p_staff_id,p_effective_from,p_agreed_daily_hours,
    '由薪資設定同步' || case
      when nullif(btrim(coalesce(p_note,'')),'') is not null
        then '：' || nullif(btrim(coalesce(p_note,'')),'')
      else ''
    end,
    (select auth.uid()),v_actor_name
  );

  select h.agreed_daily_hours
    into v_current_hours
  from public.staff_work_hours_history h
  where h.staff_id = p_staff_id
    and h.effective_from <= ((now() at time zone 'Asia/Taipei')::date)
  order by h.effective_from desc,h.created_at desc
  limit 1;

  update public.staff_users
  set agreed_daily_hours = coalesce(v_current_hours,p_agreed_daily_hours),
      updated_at = now()
  where id = p_staff_id and is_active = true;

  if not found then
    raise exception 'active staff not found or update not permitted' using errcode = 'P0002';
  end if;

  return v_rate_id;
end;
$function$;
