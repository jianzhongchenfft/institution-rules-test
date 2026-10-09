-- Snapshot of original V35 function before access-hardening.
CREATE OR REPLACE FUNCTION public.create_team_message(p_description text, p_tasks jsonb DEFAULT '[]'::jsonb, p_recipient_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
 v_id uuid;
 v_staff uuid;
 v_receiver uuid;
 v_row jsonb;
 v_task text;
 v_assignee uuid;
 v_number integer:=0;
begin
 v_staff:=private.current_staff_user_id();
 if v_staff is null or not private.can_manage_cases() then
  raise exception '您沒有使用訊息交辦的權限';
 end if;
 if p_description is null or char_length(btrim(p_description)) not between 1 and 5000 then
  raise exception '請填寫訊息說明（最多5000字）';
 end if;
 if p_tasks is null or jsonb_typeof(p_tasks)<>'array' or jsonb_array_length(p_tasks)>20 then
  raise exception '分工格式錯誤或超過20項';
 end if;
 foreach v_receiver in array coalesce(p_recipient_ids,array(
  select s.id from public.staff_users s where s.is_active
   and s.role in ('admin','organization_manager','business_manager','supervisor')
 )) loop
  if v_receiver is null or not exists(
   select 1 from public.staff_users s where s.id=v_receiver and s.is_active
    and s.role in ('admin','organization_manager','business_manager','supervisor')
  ) then raise exception '通知對象包含無效帳號';end if;
 end loop;
 insert into public.team_messages(description,created_by_staff_id)
  values (btrim(p_description),v_staff) returning id into v_id;
 insert into public.team_message_recipients(message_id,staff_id,read_at)
  values(v_id,v_staff,null);
 foreach v_receiver in array coalesce(p_recipient_ids,array(
  select s.id from public.staff_users s where s.is_active
   and s.role in ('admin','organization_manager','business_manager','supervisor')
 )) loop
  insert into public.team_message_recipients(message_id,staff_id)
   values(v_id,v_receiver) on conflict do nothing;
 end loop;
 for v_row in select value from jsonb_array_elements(p_tasks) loop
  v_number:=v_number+1;
  v_task:=btrim(coalesce(v_row->>'description',''));
  if char_length(v_task) not between 1 and 1000 then
   raise exception '第%項分工內容不可空白，最多1000字',v_number;
  end if;
  if coalesce(v_row->>'assignee_staff_id','') !~* '^[0-9a-f-]{36}$' then
   raise exception '第%項分工尚未指定承辦人',v_number;
  end if;
  v_assignee:=(v_row->>'assignee_staff_id')::uuid;
  if not exists(select 1 from public.staff_users s where s.id=v_assignee and s.is_active
   and s.role in ('admin','organization_manager','business_manager','supervisor')) then
   raise exception '第%項分工承辦人無效',v_number;
  end if;
  insert into public.team_message_tasks(message_id,description,assignee_staff_id,sort_order)
   values (v_id,v_task,v_assignee,v_number);
  insert into public.team_message_recipients(message_id,staff_id)
   values(v_id,v_assignee) on conflict do nothing;
 end loop;
 return v_id;
end $function$

