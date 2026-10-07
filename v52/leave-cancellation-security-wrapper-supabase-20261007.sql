-- V5.2 銷假 RPC 安全包裝：public 僅保留 SECURITY INVOKER wrapper，
-- 實際需提升權限的核心放在 private schema，並僅授權 authenticated 執行。

create index if not exists leave_cancellation_requested_by_idx
  on public.leave_cancellation_requests(requested_by);

create index if not exists leave_cancellation_reviewed_by_idx
  on public.leave_cancellation_requests(reviewed_by);

create or replace function private.request_leave_cancellation_core(
  p_source_type text,
  p_source_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_staff_id uuid := private.current_staff_user_id();
  v_reason text := btrim(coalesce(p_reason,''));
  v_name text;
  v_leave_date date;
  v_minutes integer;
  v_status text;
  v_id uuid;
  v_today date := ((now() at time zone 'Asia/Taipei')::date);
begin
  if v_uid is null or v_staff_id is null then
    raise exception '尚未登入。' using errcode='42501';
  end if;
  if v_reason='' then
    raise exception '請填寫銷假原因。' using errcode='P0001';
  end if;
  if p_source_type not in ('comp_leave','annual_leave') then
    raise exception '不支援的銷假類型。' using errcode='P0001';
  end if;

  if p_source_type='comp_leave' then
    select applicant_name,leave_date,minutes,status
      into v_name,v_leave_date,v_minutes,v_status
    from public.comp_leave_usages
    where id=p_source_id and applicant_staff_id=v_staff_id
    for update;
  else
    select applicant_name,leave_date,minutes,status
      into v_name,v_leave_date,v_minutes,v_status
    from public.annual_leave_requests
    where id=p_source_id and applicant_staff_id=v_staff_id
    for update;
  end if;

  if v_name is null then
    raise exception '找不到可申請銷假的紀錄。' using errcode='P0001';
  end if;
  if v_status<>'approved' then
    raise exception '只有已核准的假別可以申請銷假。' using errcode='P0001';
  end if;
  if v_leave_date<=v_today then
    raise exception '休假日已到或已過，請聯繫管理者處理。' using errcode='P0001';
  end if;
  if exists(
    select 1 from public.leave_cancellation_requests
    where source_type=p_source_type and source_id=p_source_id and status='pending'
  ) then
    raise exception '此筆假別已有待審核的銷假申請。' using errcode='P0001';
  end if;

  insert into public.leave_cancellation_requests(
    source_type,source_id,applicant_staff_id,applicant_name,leave_date,minutes,
    reason,status,requested_by,requested_at,created_at,updated_at
  ) values(
    p_source_type,p_source_id,v_staff_id,v_name,v_leave_date,v_minutes,
    v_reason,'pending',v_uid,now(),now(),now()
  )
  returning id into v_id;

  return jsonb_build_object('id',v_id,'status','pending');
end;
$$;

create or replace function private.review_leave_cancellation_core(
  p_id uuid,
  p_action text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_req public.leave_cancellation_requests%rowtype;
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
  v_source_status text;
begin
  if v_uid is null then
    raise exception '尚未登入。' using errcode='42501';
  end if;
  if p_action not in ('approve','reject') then
    raise exception '不支援的銷假審核動作。' using errcode='P0001';
  end if;

  select * into v_req
  from public.leave_cancellation_requests
  where id=p_id
  for update;

  if not found or v_req.status<>'pending' then
    raise exception '此銷假申請目前不是待審核狀態。' using errcode='P0001';
  end if;

  if v_req.source_type='comp_leave' then
    if not coalesce(private.can_review_overtime(),false) then
      raise exception '目前帳號沒有換休銷假審核權限。' using errcode='42501';
    end if;

    if p_action='approve' then
      select status into v_source_status
      from public.comp_leave_usages
      where id=v_req.source_id
      for update;

      if v_source_status<>'approved' then
        raise exception '原換休紀錄已不是已核准狀態，請重新整理後確認。' using errcode='P0001';
      end if;

      update public.comp_leave_usages
      set status='voided',
          void_reason='銷假：'||v_req.reason,
          voided_by=v_uid,
          voided_at=now(),
          review_note=case
            when coalesce(review_note,'')='' then '銷假核准：'||v_req.reason
            else review_note||E'\n銷假核准：'||v_req.reason
          end,
          updated_at=now()
      where id=v_req.source_id;
    end if;
  else
    if not coalesce(private.can_review_annual_leave(),false) then
      raise exception '目前帳號沒有特休銷假審核權限。' using errcode='42501';
    end if;

    if p_action='approve' then
      select status into v_source_status
      from public.annual_leave_requests
      where id=v_req.source_id
      for update;

      if v_source_status<>'approved' then
        raise exception '原特休紀錄已不是已核准狀態，請重新整理後確認。' using errcode='P0001';
      end if;

      update public.annual_leave_requests
      set status='voided',
          void_reason='銷假：'||v_req.reason,
          voided_by=v_uid,
          voided_at=now(),
          review_note=case
            when coalesce(review_note,'')='' then '銷假核准：'||v_req.reason
            else review_note||E'\n銷假核准：'||v_req.reason
          end,
          updated_at=now()
      where id=v_req.source_id;
    end if;
  end if;

  update public.leave_cancellation_requests
  set status=case when p_action='approve' then 'approved' else 'rejected' end,
      reviewed_by=v_uid,
      reviewed_at=now(),
      review_note=v_note,
      updated_at=now()
  where id=v_req.id;

  return jsonb_build_object(
    'id',v_req.id,
    'status',case when p_action='approve' then 'approved' else 'rejected' end
  );
end;
$$;

revoke all on function private.request_leave_cancellation_core(text,uuid,text) from public, anon;
revoke all on function private.review_leave_cancellation_core(uuid,text,text) from public, anon;
grant execute on function private.request_leave_cancellation_core(text,uuid,text) to authenticated;
grant execute on function private.review_leave_cancellation_core(uuid,text,text) to authenticated;

create or replace function public.request_leave_cancellation(
  p_source_type text,
  p_source_id uuid,
  p_reason text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.request_leave_cancellation_core(p_source_type,p_source_id,p_reason);
$$;

create or replace function public.review_leave_cancellation(
  p_id uuid,
  p_action text,
  p_note text default null
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.review_leave_cancellation_core(p_id,p_action,p_note);
$$;

revoke all on function public.request_leave_cancellation(text,uuid,text) from public, anon;
revoke all on function public.review_leave_cancellation(uuid,text,text) from public, anon;
grant execute on function public.request_leave_cancellation(text,uuid,text) to authenticated;
grant execute on function public.review_leave_cancellation(uuid,text,text) to authenticated;
