-- LiuXinZi TEST only: in-place case contact editing; preserves referenced IDs.
CREATE OR REPLACE FUNCTION public.update_case_profile(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_case_id uuid := nullif(payload->>'case_id','')::uuid;
  v_old_supervisor uuid;
  v_old_conditions text;
  v_old_treatments text;
  v_new_conditions text;
  v_new_treatments text;
  v_new_supervisor uuid := nullif(payload->>'supervisor_id','')::uuid;
  v_case_no text := upper(regexp_replace(btrim(coalesce(payload->>'case_no','')),'\s+','','g'));
  v_case_name text := btrim(coalesce(payload->>'case_name',''));
  v_usage text := nullif(btrim(payload->>'service_usage_type'),'');
  v_payment text := nullif(btrim(payload->>'payment_method'),'');
  v_welfare text := nullif(btrim(payload->>'welfare_identity'),'');
  v_status text := coalesce(nullif(payload->>'service_status',''),'active');
  v_staff_id uuid;
  v_staff_role text;
  v_contacts jsonb := coalesce(payload->'contacts','[]'::jsonb);
  item jsonb;
  v_contact_id uuid;
  v_keep_contact_ids uuid[] := array[]::uuid[];
  v_old_primary_id uuid;
begin
  if v_case_id is null then raise exception '缺少個案資料'; end if;

  select c.supervisor_id,c.important_conditions,c.ongoing_treatments
    into v_old_supervisor,v_old_conditions,v_old_treatments
  from public.care_cases c
  where c.id=v_case_id;

  if not found then raise exception '找不到個案'; end if;

  v_new_conditions:=case
    when payload ? 'important_conditions' then nullif(btrim(payload->>'important_conditions'),'')
    else v_old_conditions
  end;
  v_new_treatments:=case
    when payload ? 'ongoing_treatments' then nullif(btrim(payload->>'ongoing_treatments'),'')
    else v_old_treatments
  end;
  if not private.can_edit_case(v_old_supervisor) then raise exception '沒有修改此個案的權限'; end if;

  select s.id,s.role into v_staff_id,v_staff_role
  from public.staff_users s
  where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
    and s.is_active=true
  limit 1;

  if v_case_no='' then raise exception '個案編號為必填'; end if;
  if v_case_no ~ '\s' then raise exception '個案編號不可包含空格'; end if;
  if v_case_name='' then raise exception '個案姓名為必填'; end if;
  if v_usage is null or v_usage not in ('居家','喘息','居家+喘息') then
    raise exception '服務類別格式不正確';
  end if;
  if v_payment is not null and v_payment not in ('銀行匯款','超商繳款','現金繳費','不收費') then
    raise exception '繳款方式格式不正確';
  end if;
  if v_welfare='低收入戶' then
    v_payment:='不收費';
  elsif v_welfare in ('中低收入戶','一般戶') and v_payment='不收費' then
    raise exception '第二類／第三類個案不可設定為不收費';
  end if;
  if v_status not in ('active','suspended','closed') then
    raise exception '服務狀態格式不正確';
  end if;
  if v_new_supervisor is null then raise exception '負責督導為必填'; end if;
  if nullif(btrim(payload->>'google_maps_url'),'') is not null and not (btrim(payload->>'google_maps_url') ~ '^https://((www\.)?google\.com/maps([/?#]|$)|maps\.google\.com/|maps\.app\.goo\.gl/|goo\.gl/maps([/?#]|$))') then
    raise exception '請輸入有效的 Google Maps 連結';
  end if;

  if not exists(
    select 1 from public.staff_users s
    where s.id=v_new_supervisor and s.is_active=true and s.can_supervise=true
  ) then
    raise exception '所選人員目前不是可指派的督導';
  end if;

  if v_staff_role='supervisor' and v_new_supervisor is distinct from v_old_supervisor then
    raise exception '督導不可自行變更個案負責督導';
  end if;

  if v_old_conditions is distinct from v_new_conditions then
    insert into public.case_health_profile_history(
      case_id,field_name,old_value,new_value,changed_by
    ) values(
      v_case_id,'important_conditions',v_old_conditions,v_new_conditions,(select auth.uid())
    );
  end if;

  if v_old_treatments is distinct from v_new_treatments then
    insert into public.case_health_profile_history(
      case_id,field_name,old_value,new_value,changed_by
    ) values(
      v_case_id,'ongoing_treatments',v_old_treatments,v_new_treatments,(select auth.uid())
    );
  end if;

  update public.care_cases
  set case_no=v_case_no,
      case_name=v_case_name,
      supervisor_id=v_new_supervisor,
      open_date=case when payload ? 'open_date' then nullif(payload->>'open_date','')::date else open_date end,
      google_maps_url=case when payload ? 'google_maps_url' then nullif(btrim(payload->>'google_maps_url'),'') else google_maps_url end,
      national_id=nullif(upper(btrim(payload->>'national_id')),''),
      birth_date=nullif(payload->>'birth_date','')::date,
      gender=nullif(payload->>'gender',''),
      address=nullif(btrim(payload->>'address'),''),
      phone=nullif(btrim(payload->>'phone'),''),
      lives_alone=case when payload ? 'lives_alone' and nullif(payload->>'lives_alone','') is not null then (payload->>'lives_alone')::boolean else lives_alone end,
      has_dementia=case when payload ? 'has_dementia' and nullif(payload->>'has_dementia','') is not null then (payload->>'has_dementia')::boolean else has_dementia end,
      cms_level=nullif(btrim(payload->>'cms_level'),''),
      identity_type=nullif(btrim(payload->>'identity_type'),''),
      has_disability=case when payload ? 'has_disability' and nullif(payload->>'has_disability','') is not null then (payload->>'has_disability')::boolean else null end,
      is_indigenous=case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null then (payload->>'is_indigenous')::boolean else null end,
      indigenous_group=case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null and (payload->>'is_indigenous')::boolean=false then null else nullif(btrim(payload->>'indigenous_group'),'') end,
      welfare_identity=nullif(btrim(payload->>'welfare_identity'),''),
      copay_rate=case nullif(btrim(payload->>'welfare_identity'),'') when '一般戶' then 16 when '中低收入戶' then 5 when '低收入戶' then 0 else nullif(payload->>'copay_rate','')::numeric end,
      a_unit_name=nullif(btrim(payload->>'a_unit_name'),''),
      case_manager_name=nullif(btrim(payload->>'case_manager_name'),''),
      case_manager_phone=nullif(btrim(payload->>'case_manager_phone'),''),
      assessor_name=nullif(btrim(payload->>'assessor_name'),''),
      important_conditions=v_new_conditions,
      ongoing_treatments=v_new_treatments,
      service_usage_type=v_usage,
      payment_method=v_payment,
      service_status=v_status,
      notes=nullif(btrim(payload->>'notes'),''),
      updated_at=now()
  where id=v_case_id;

  if v_new_supervisor is distinct from v_old_supervisor then
    update public.case_supervisor_assignments
    set is_current=false, assigned_to=current_date
    where case_id=v_case_id and is_current=true;

    insert into public.case_supervisor_assignments(
      case_id,supervisor_id,assigned_from,is_current,created_by
    ) values(
      v_case_id,v_new_supervisor,current_date,true,(select auth.uid())
    );
  end if;

  if payload ? 'contacts' then
    if jsonb_typeof(v_contacts) <> 'array' then
      raise exception '聯絡人資料格式不正確';
    end if;
    if (select count(*) from jsonb_array_elements(v_contacts) x
        where x->>'is_primary_contact'='true'
          and btrim(coalesce(x->>'contact_name',''))<>'') > 1 then
      raise exception '每位個案只能指定一位主要聯絡人';
    end if;

    -- 既有聯絡人使用穩定 ID；防止過期資料、跨個案 ID 與重複 ID。
    for item in select value from jsonb_array_elements(v_contacts) loop
      if btrim(coalesce(item->>'contact_name',''))<>'' then
        v_contact_id := nullif(item->>'id','')::uuid;
        if v_contact_id is not null then
          if v_contact_id = any(v_keep_contact_ids) then
            raise exception '聯絡人識別碼重複，請重新開啟個案資料後再儲存';
          end if;
          if not exists (
            select 1 from public.case_contacts cc
             where cc.id=v_contact_id and cc.case_id=v_case_id
          ) then
            raise exception '聯絡人資料已變更或不屬於此個案，請重新載入';
          end if;
          v_keep_contact_ids:=array_append(v_keep_contact_ids,v_contact_id);
        elsif exists (
          select 1 from public.case_contacts cc
           where cc.case_id=v_case_id
             and cc.contact_name=btrim(item->>'contact_name')
        ) then
          raise exception '既有聯絡人缺少識別碼，請重新整理編輯畫面後再儲存';
        end if;
      end if;
    end loop;

    if exists (
      select 1 from public.case_contacts cc
       where cc.case_id=v_case_id
         and not (cc.id=any(v_keep_contact_ids))
         and exists (
           select 1 from public.case_contact_record_people rp
            where rp.case_contact_id=cc.id
         )
    ) then
      raise exception '聯絡人已有家訪／電訪紀錄，無法刪除；請保留該聯絡人';
    end if;

    -- 只有主要聯絡人真的改變時才清除舊旗標，避免唯一索引衝突。
    select cc.id into v_old_primary_id
      from public.case_contacts cc
     where cc.case_id=v_case_id and cc.is_primary_contact
     limit 1;
    if v_old_primary_id is not null and not exists (
      select 1 from jsonb_array_elements(v_contacts) x
       where x->>'id'=v_old_primary_id::text
         and x->>'is_primary_contact'='true'
         and btrim(coalesce(x->>'contact_name',''))<>''
    ) then
      update public.case_contacts
         set is_primary_contact=false, updated_at=now()
       where id=v_old_primary_id;
    end if;

    for item in select value from jsonb_array_elements(v_contacts) loop
      if btrim(coalesce(item->>'contact_name',''))<>'' then
        v_contact_id := nullif(item->>'id','')::uuid;
        if v_contact_id is not null then
          update public.case_contacts cc
             set contact_name=btrim(item->>'contact_name'),
                 relationship=nullif(btrim(item->>'relationship'),''),
                 phone=nullif(btrim(item->>'phone'),''),
                 is_primary_contact=coalesce(item->>'is_primary_contact','false')='true',
                 is_primary_caregiver=coalesce(item->>'is_primary_caregiver','false')='true',
                 is_secondary_caregiver=coalesce(item->>'is_secondary_caregiver','false')='true',
                 updated_at=now()
           where cc.id=v_contact_id and cc.case_id=v_case_id
             and (cc.contact_name,cc.relationship,cc.phone,cc.is_primary_contact,
                  cc.is_primary_caregiver,cc.is_secondary_caregiver)
                 is distinct from
                 (btrim(item->>'contact_name'),nullif(btrim(item->>'relationship'),''),
                  nullif(btrim(item->>'phone'),''),
                  coalesce(item->>'is_primary_contact','false')='true',
                  coalesce(item->>'is_primary_caregiver','false')='true',
                  coalesce(item->>'is_secondary_caregiver','false')='true');
        else
          insert into public.case_contacts (
            case_id,contact_name,relationship,phone,is_primary_contact,
            is_primary_caregiver,is_secondary_caregiver,notes,source,source_import_id
          ) values (
            v_case_id,btrim(item->>'contact_name'),
            nullif(btrim(item->>'relationship'),''),
            nullif(btrim(item->>'phone'),''),
            coalesce(item->>'is_primary_contact','false')='true',
            coalesce(item->>'is_primary_caregiver','false')='true',
            coalesce(item->>'is_secondary_caregiver','false')='true',
            nullif(btrim(item->>'notes','')),'manual',null
          ) returning id into v_contact_id;
          v_keep_contact_ids:=array_append(v_keep_contact_ids,v_contact_id);
        end if;
      end if;
    end loop;

    -- 只刪除明確移除且沒有歷史引用的聯絡人。
    delete from public.case_contacts cc
     where cc.case_id=v_case_id
       and not (cc.id=any(v_keep_contact_ids));
  end if;

  return jsonb_build_object('case_id',v_case_id,'updated',true);
end;
$function$
;
