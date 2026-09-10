-- V5.2 加班／換休：待審核申請撤回改為直接刪除
-- 僅允許申請本人刪除自己仍為 pending 的資料。

drop policy if exists overtime_delete_own_pending on public.overtime_requests;
create policy overtime_delete_own_pending
on public.overtime_requests
for delete
to authenticated
using (
  applicant_staff_id = (select private.current_staff_user_id())
  and created_by = (select auth.uid())
  and status = 'pending'
  and (select private.can_submit_overtime())
);

drop policy if exists comp_leave_delete_own_pending on public.comp_leave_usages;
create policy comp_leave_delete_own_pending
on public.comp_leave_usages
for delete
to authenticated
using (
  applicant_staff_id = (select private.current_staff_user_id())
  and created_by = (select auth.uid())
  and status = 'pending'
  and (select private.can_submit_overtime())
);
