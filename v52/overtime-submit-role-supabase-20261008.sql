-- V5.2 加班／換休申請角色
-- 機構負責人與系統管理員、業務負責人、督導皆可申請自己的加班／換休。

create or replace function private.can_submit_overtime()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    private.current_staff_user_role() in (
      'supervisor',
      'business_manager',
      'organization_manager',
      'admin'
    ),
    false
  );
$function$;
