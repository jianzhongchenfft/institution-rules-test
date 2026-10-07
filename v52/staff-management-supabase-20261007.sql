-- Personnel management V1
-- Shared attendance fields remain in public.staff_users.
-- No new annual-leave settings table or duplicate personnel table is introduced.
--
-- RLS already restricts staff_users UPDATE to organization_manager / admin
-- through the existing overtime-reviewer update policy.
grant update (regular_day_weekday) on table public.staff_users to authenticated;
