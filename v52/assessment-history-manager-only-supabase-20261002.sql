-- V5.2 評估管理：修改歷程僅限管理者查閱
-- TEST migration mirror
-- 日期：2026-10-02

create or replace function private.can_view_assessment_history()
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select exists (
    select 1
    from public.staff_users s
    where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
      and s.is_active=true
      and s.role in ('business_manager','organization_manager','admin')
  );
$$;

revoke all on function private.can_view_assessment_history() from public,anon;
grant execute on function private.can_view_assessment_history() to authenticated;

drop policy if exists assessment_adl_history_read on public.assessment_adl_history;
create policy assessment_adl_history_read
on public.assessment_adl_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_iadl_history_read on public.assessment_iadl_history;
create policy assessment_iadl_history_read
on public.assessment_iadl_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_spmsq_history_read on public.assessment_spmsq_history;
create policy assessment_spmsq_history_read
on public.assessment_spmsq_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_gds15_history_read on public.assessment_gds15_history;
create policy assessment_gds15_history_read
on public.assessment_gds15_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_health_history_read on public.assessment_health_history;
create policy assessment_health_history_read
on public.assessment_health_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_home_safety_history_read on public.assessment_home_safety_history;
create policy assessment_home_safety_history_read
on public.assessment_home_safety_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_support_history_read on public.assessment_support_history;
create policy assessment_support_history_read
on public.assessment_support_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_caregiver_screen_history_read on public.assessment_caregiver_screen_history;
create policy assessment_caregiver_screen_history_read
on public.assessment_caregiver_screen_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_event_summary_history_read on public.assessment_event_summary_history;
create policy assessment_event_summary_history_read
on public.assessment_event_summary_history
for select to authenticated
using (private.can_view_assessment_history());
