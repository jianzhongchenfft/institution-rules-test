-- V36 rollback (test environment only).
-- Restore previous security-invoker behavior and original table INSERT grants.
grant insert on table
 public.team_messages,
 public.team_message_tasks,
 public.team_message_recipients
to authenticated;
alter function public.create_team_message(text,jsonb,uuid[]) security invoker;
