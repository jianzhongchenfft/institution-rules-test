-- 測試版｜共用評估單項總結。原評估表/歷史紀錄不更動
create table if not exists public.assessment_tool_summaries (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id),
  tool_code text not null check (tool_code in ('adl','iadl','spmsq','gds15','health_medication','home_safety','support','caregiver_burden','overall')),
  findings text not null default '',
  recommendations text not null default '',
  source_signature text not null default '',
  has_generated boolean not null default false,
  created_by uuid not null default auth.uid(),
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (assessment_event_id,tool_code)
);
create index if not exists assessment_tool_summaries_case_idx on public.assessment_tool_summaries(case_id);
alter table public.assessment_tool_summaries enable row level security;
drop policy if exists assessment_tool_summaries_read on public.assessment_tool_summaries;
create policy assessment_tool_summaries_read on public.assessment_tool_summaries
  for select to authenticated using (private.can_manage_cases());
drop policy if exists assessment_tool_summaries_insert on public.assessment_tool_summaries;
create policy assessment_tool_summaries_insert on public.assessment_tool_summaries
  for insert to authenticated with check (
    created_by=auth.uid() and
    exists (
      select 1 from public.assessment_events e
      where e.id=assessment_event_id and e.case_id=case_id
        and e.status <> 'voided' and private.can_edit_assessment_case(e.case_id)
    )
  );
drop policy if exists assessment_tool_summaries_update on public.assessment_tool_summaries;
create policy assessment_tool_summaries_update on public.assessment_tool_summaries
  for update to authenticated
  using (exists(select 1 from public.assessment_events e
    where e.id=assessment_event_id and e.case_id=case_id
      and e.status <> 'voided' and private.can_edit_assessment_case(e.case_id)))
  with check (exists(select 1 from public.assessment_events e
    where e.id=assessment_event_id and e.case_id=case_id
      and e.status <> 'voided' and private.can_edit_assessment_case(e.case_id)));
grant select,insert,update on public.assessment_tool_summaries to authenticated;
revoke all on public.assessment_tool_summaries from anon;
