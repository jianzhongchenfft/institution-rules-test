-- Personnel management V1
-- Shared attendance fields remain in public.staff_users.
-- No new annual-leave settings table or duplicate personnel table is introduced.
--
-- RLS already restricts staff_users UPDATE to organization_manager / admin
-- through the existing overtime-reviewer update policy.
grant update (regular_day_weekday) on table public.staff_users to authenticated;

-- When current employment basics become usable or are changed,
-- immediately run the existing annual-leave generator.
-- The daily 00:10 Asia/Taipei cron remains as a fallback/safety net.
create or replace function private.refresh_annual_leave_after_staff_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if tg_op = 'INSERT' then
    if new.is_active is distinct from true
       or new.hire_date is null
       or new.agreed_daily_hours is null then
      return new;
    end if;
  else
    if not (
      old.hire_date is distinct from new.hire_date
      or old.agreed_daily_hours is distinct from new.agreed_daily_hours
      or old.is_active is distinct from new.is_active
    ) then
      return new;
    end if;

    if new.is_active is distinct from true
       or new.hire_date is null
       or new.agreed_daily_hours is null then
      return new;
    end if;
  end if;

  perform private.generate_annual_leave_credits(
    (now() at time zone 'Asia/Taipei')::date
  );

  return new;
end;
$function$;

revoke all on function private.refresh_annual_leave_after_staff_change() from public;
revoke all on function private.refresh_annual_leave_after_staff_change() from anon;
revoke all on function private.refresh_annual_leave_after_staff_change() from authenticated;

drop trigger if exists trg_staff_annual_leave_insert on public.staff_users;
create trigger trg_staff_annual_leave_insert
after insert on public.staff_users
for each row
execute function private.refresh_annual_leave_after_staff_change();

drop trigger if exists trg_staff_annual_leave_profile_update on public.staff_users;
create trigger trg_staff_annual_leave_profile_update
after update of hire_date, agreed_daily_hours, is_active on public.staff_users
for each row
execute function private.refresh_annual_leave_after_staff_change();
