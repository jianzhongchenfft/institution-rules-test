-- 訊息交辦：側邊欄提醒依訊息去重，保持原本待辦與建立者提醒條件。
-- 只更新測試版 Supabase；不調整資料表、RLS 或既有權限。
create or replace function public.team_message_attention_count()
returns integer
language sql
stable
set search_path to ''
as $function$
select case when not private.can_manage_cases() then 0 else
 (
  select count(*)::integer from (
   select t.message_id
   from public.team_message_tasks t
   join public.team_messages m on m.id=t.message_id
   where m.closed_at is null
     and t.cancelled_at is null
     and t.assignee_staff_id=private.current_staff_user_id()
     and not t.is_done
   union
   select m.id
   from public.team_messages m
   where m.closed_at is null
     and m.created_by_staff_id=private.current_staff_user_id()
     and exists (select 1 from public.team_message_tasks t where t.message_id=m.id)
     and (
      not exists (
       select 1 from public.team_message_tasks t
       where t.message_id=m.id and t.cancelled_at is null and not t.is_done
      )
      or exists (
       select 1 from public.team_message_tasks t
       where t.message_id=m.id and t.cancelled_at is null and t.assistance_needed
      )
     )
  ) attention_messages
 )
end;
$function$;
