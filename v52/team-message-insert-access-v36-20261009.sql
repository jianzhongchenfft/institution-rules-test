-- V36: test Supabase only. Keep creation/assignment/recipient writes in validated RPC functions.
-- Existing create_team_message enforces logged-in active staff role, content and recipient validation, 20-task maximum.
-- It already has SET search_path TO '' and explicit public/private schema qualifications.
alter function public.create_team_message(text,jsonb,uuid[]) security definer;

-- After SECURITY DEFINER has been enabled, direct INSERT is no longer needed.
-- Keep SELECT permissions, own read_at UPDATE, and creator-only closed_at UPDATE unchanged.
revoke insert on table
  public.team_messages,
  public.team_message_tasks,
  public.team_message_recipients
from authenticated;
