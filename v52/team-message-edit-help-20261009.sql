-- 訊息交辦：待回覆執行困難可更新最新說明；建立者回覆後原紀錄鎖定。
-- 新增直接對應的系統歷程 ID，絕不以文字搜尋識別日後的修改目標。
alter table public.team_message_tasks
 add column if not exists help_note text,
 add column if not exists help_update_id uuid references public.team_message_updates(id);
alter table public.team_message_tasks
 add constraint team_message_help_note_size
 check (help_note is null or char_length(btrim(help_note)) between 1 and 1700);
alter table public.team_message_tasks
 add constraint team_message_help_note_pair
 check ((help_note is null) = (help_update_id is null));

-- 一次性承接過去尚待回覆的困難，之後所有新紀錄皆以 help_update_id 直接關聯。
with matched as (
 select distinct on (t.id)
   t.id as task_id, u.id as update_id,
   substring(u.body from position(E'\n' in u.body)+1) as latest_note
 from public.team_message_tasks t
 join public.team_messages m on m.id=t.message_id
 join public.team_message_updates u on u.message_id=t.message_id
    and u.staff_id=t.assignee_staff_id and u.is_system and u.voided_at is null
 where t.assistance_needed and t.cancelled_at is null and m.closed_at is null
   and u.body like ('【執行困難｜'||left(t.description,110)||'】'||E'\n%')
 order by t.id,u.created_at desc,u.id desc
)
update public.team_message_tasks t
 set help_note=a.latest_note,help_update_id=a.update_id
 from matched a where t.id=a.task_id;

-- 保留原本的承辦權限、狀態檢查、既有操作與稽核。
CREATE OR REPLACE FUNCTION public.team_message_task_action(p_task_id uuid, p_action text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_actor uuid;
 v_mid uuid;
 v_assignee uuid;
 v_assignee_name text;
 v_creator uuid;
 v_closed timestamptz;
 v_done boolean;
 v_help boolean;
 v_instruction boolean;
 v_cancelled timestamptz;
 v_description text;
 v_note text:=btrim(coalesce(p_note,''));
 v_audit text;
 v_audit_id uuid;
begin
 v_actor:=private.current_staff_user_id();
 if v_actor is null or not private.can_manage_cases() then raise exception '沒有操作訊息交辦的權限';end if;
 select t.message_id,t.assignee_staff_id,m.created_by_staff_id,m.closed_at,
        t.is_done,t.assistance_needed,t.instruction_pending,t.cancelled_at,t.description,
        s.display_name
 into v_mid,v_assignee,v_creator,v_closed,v_done,v_help,v_instruction,v_cancelled,v_description,v_assignee_name
 from public.team_message_tasks t
 join public.team_messages m on m.id=t.message_id
 left join public.staff_users s on s.id=t.assignee_staff_id
 where t.id=p_task_id
 for update of t,m;
 if not found then raise exception '分工不存在';end if;
 if v_closed is not null then raise exception '結案後不得修改分工';end if;
 if v_cancelled is not null then raise exception '已取消的分工不可再操作';end if;

 if p_action='request_help' then
   if v_actor<>v_assignee or v_done or v_help or v_instruction then
     raise exception '只有尚未完成且沒有新指示待確認的承辦人可回報執行困難';
   end if;
   if char_length(v_note) not between 1 and 1700 then raise exception '請填寫執行困難原因';end if;
   update public.team_message_tasks set assistance_needed=true,instruction_pending=false where id=p_task_id;
   v_audit:='【執行困難｜'||left(v_description,110)||'】'||E'\n'||v_note;
 elsif p_action='guide' then
   if v_actor<>v_creator or not v_help then raise exception '只有建立者可對執行困難提供新指示';end if;
   if char_length(v_note) not between 1 and 1700 then raise exception '請填寫新指示';end if;
   update public.team_message_tasks set assistance_needed=false,instruction_pending=true where id=p_task_id;
   v_audit:='【新指示｜'||left(v_description,110)||'】'||E'\n'||v_note;
 elsif p_action='redo' then
   if v_actor<>v_creator or not v_done then raise exception '只有建立者可將已完成分工退回重辦';end if;
   if char_length(v_note) not between 1 and 1700 then raise exception '請填寫退回重辦的指示';end if;
   update public.team_message_tasks set is_done=false,assistance_needed=false,instruction_pending=true where id=p_task_id;
   v_audit:='【退回重辦｜'||left(v_description,110)||'】'||E'\n'||v_note;
 elsif p_action='ack' then
   if v_actor<>v_assignee or not v_instruction then raise exception '沒有待確認的新指示';end if;
   update public.team_message_tasks set instruction_pending=false where id=p_task_id;
 elsif p_action='complete' then
   if v_done then raise exception '此項分工已完成';end if;
   if v_help or v_instruction then raise exception '執行困難或新指示待確認時，不能勾選完成';end if;
   update public.team_message_tasks set is_done=true where id=p_task_id;
   v_audit:='【分工完成｜'||left(v_description,220)||'】（承辦人：'||left(coalesce(v_assignee_name,'原承辦人'),70)||'）';
 elsif p_action='reopen' then
   if not v_done then raise exception '此項分工尚未完成';end if;
   update public.team_message_tasks set is_done=false where id=p_task_id;
   v_audit:='【取消完成勾選｜'||left(v_description,220)||'】（承辦人：'||left(coalesce(v_assignee_name,'原承辦人'),70)||'）';
 else
   raise exception '未知分工操作';
 end if;
 if v_audit is not null then
   insert into public.team_message_updates(message_id,staff_id,body,is_system)
   values(v_mid,v_actor,v_audit,true) returning id into v_audit_id;
   if p_action='request_help' then
     update public.team_message_tasks
       set help_note=v_note,help_update_id=v_audit_id where id=p_task_id;
   end if;
 end if;
 return v_mid;
end;
$function$


create or replace function public.team_message_edit_help(p_task_id uuid,p_note text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
 v_actor uuid;
 v_assignee uuid;
 v_creator uuid;
 v_mid uuid;
 v_update_id uuid;
 v_note text:=btrim(coalesce(p_note,''));
 v_old_note text;
 v_description text;
 v_help boolean;
 v_instruction boolean;
 v_done boolean;
 v_cancelled timestamptz;
 v_closed timestamptz;
 v_updated uuid;
begin
 v_actor:=private.current_staff_user_id();
 if v_actor is null or not private.can_manage_cases() then
  raise exception '沒有操作訊息交辦的權限';
 end if;
 select t.message_id,t.assignee_staff_id,m.created_by_staff_id,
        t.help_update_id,t.help_note,t.description,
        t.assistance_needed,t.instruction_pending,t.is_done,t.cancelled_at,m.closed_at
 into v_mid,v_assignee,v_creator,v_update_id,v_old_note,v_description,
      v_help,v_instruction,v_done,v_cancelled,v_closed
 from public.team_message_tasks t
 join public.team_messages m on m.id=t.message_id
 where t.id=p_task_id
 for update of t,m;
 if not found then raise exception '分工不存在';end if;
 if v_actor<>v_assignee then raise exception '只有原承辦人能修改自己的執行困難';end if;
 if v_closed is not null or v_cancelled is not null or v_done or not v_help or v_instruction then
  raise exception '建立者已回覆，或分工已完成、取消、結案，不能再修改原困難';
 end if;
 if char_length(v_note) not between 1 and 1700 then
  raise exception '執行困難說明不可空白，最多1700字';
 end if;
 if v_update_id is null or v_old_note is null then
  raise exception '找不到本次執行困難的原始歷程，請聯繫管理者';
 end if;
 if v_note=v_old_note then raise exception '執行困難說明沒有變更';end if;
 update public.team_message_updates u
 set body='【執行困難｜'||left(v_description,110)||'】'||E'\n'||v_note
 where u.id=v_update_id and u.message_id=v_mid and u.staff_id=v_assignee
   and u.is_system and u.voided_at is null
 returning u.id into v_updated;
 if v_updated is null then raise exception '原始執行困難紀錄不存在或無法修改';end if;
 update public.team_message_tasks set help_note=v_note where id=p_task_id;
 update public.team_message_recipients
 set read_at=null where message_id=v_mid and staff_id=v_creator;
 return v_mid;
end;
$function$;
revoke all on function public.team_message_edit_help(uuid,text) from public,anon;
grant execute on function public.team_message_edit_help(uuid,text) to authenticated;
