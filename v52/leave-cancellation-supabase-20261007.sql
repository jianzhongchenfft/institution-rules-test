-- V5.2 換休／特休銷假流程
create table if not exists public.leave_cancellation_requests (
  id uuid primary key default gen_random_uuid(),
  source_type text not null check (source_type in ('comp_leave','annual_leave')),
  source_id uuid not null,
  applicant_staff_id uuid not null references public.staff_users(id) on delete restrict,
  applicant_name text not null,
  leave_date date not null,
  minutes integer not null check (minutes > 0),
  reason text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_by uuid not null references auth.users(id) on delete restrict,
  requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete restrict,
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists leave_cancellation_one_pending_per_source
  on public.leave_cancellation_requests(source_type,source_id)
  where status='pending';

create index if not exists leave_cancellation_applicant_idx
  on public.leave_cancellation_requests(applicant_staff_id,status,leave_date);

alter table public.leave_cancellation_requests enable row level security;

drop policy if exists leave_cancellation_read on public.leave_cancellation_requests;
create policy leave_cancellation_read
on public.leave_cancellation_requests
for select
to authenticated
using (
  applicant_staff_id = (select private.current_staff_user_id())
  or (select private.can_review_overtime())
  or (select private.can_review_annual_leave())
);

revoke all on public.leave_cancellation_requests from anon, authenticated;
grant select on public.leave_cancellation_requests to authenticated;

create or replace function public.request_leave_cancellation(
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

create or replace function public.review_leave_cancellation(
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

    select status into v_source_status
    from public.comp_leave_usages
    where id=v_req.source_id
    for update;

    if v_source_status<>'approved' then
      raise exception '原換休紀錄已不是已核准狀態，請重新整理後確認。' using errcode='P0001';
    end if;

    if p_action='approve' then
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

    select status into v_source_status
    from public.annual_leave_requests
    where id=v_req.source_id
    for update;

    if v_source_status<>'approved' then
      raise exception '原特休紀錄已不是已核准狀態，請重新整理後確認。' using errcode='P0001';
    end if;

    if p_action='approve' then
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

revoke all on function public.request_leave_cancellation(text,uuid,text) from public, anon;
revoke all on function public.review_leave_cancellation(uuid,text,text) from public, anon;
grant execute on function public.request_leave_cancellation(text,uuid,text) to authenticated;
grant execute on function public.review_leave_cancellation(uuid,text,text) to authenticated;
