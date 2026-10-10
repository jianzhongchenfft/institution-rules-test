-- LiuXinZi TEST only: preserve linked HTML-import contact IDs during re-import.
CREATE OR REPLACE FUNCTION public.import_case_html_data(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_case_id uuid;
  v_plan_id uuid;
  v_import_id uuid;
  v_action text;
  v_case_no text := upper(regexp_replace(btrim(coalesce(payload->>'case_no','')),'\s+','','g'));
  v_national_id text := upper(btrim(coalesce(payload->>'national_id','')));
  v_supervisor uuid := nullif(payload->>'supervisor_id','')::uuid;
  v_match_case uuid := nullif(payload->>'match_case_id','')::uuid;
  v_service_usage_type text := nullif(btrim(payload->>'service_usage_type'),'');
  v_payment_method text := nullif(btrim(payload->>'payment_method'),'');
  v_welfare_identity text := nullif(btrim(payload->>'welfare_identity'),'');
  v_staff_id uuid;
  v_staff_role text;
  v_existing_case_no text;
  v_existing_supervisor uuid;
  v_hash text := nullif(payload->>'source_hash','');
  v_plan jsonb := coalesce(payload->'care_plan','{}'::jsonb);
  v_contacts jsonb := coalesce(payload->'contacts','[]'::jsonb);
  v_services jsonb := coalesce(payload->'services','[]'::jsonb);
  v_budgets jsonb := coalesce(payload->'budgets','[]'::jsonb);
  v_current_plan_id uuid;
  v_import_is_current boolean := false;
  item jsonb;
  v_import_contact_id uuid;
  v_import_keep_ids uuid[] := array[]::uuid[];
begin
  if (select auth.uid()) is null or not private.can_manage_cases() then
    raise exception '沒有個案管理權限';
  end if;

  if v_case_no='' then raise exception '個案編號為必填'; end if;
  if v_case_no ~ '\s' then raise exception '個案編號不可包含空格'; end if;
  if v_service_usage_type is null or v_service_usage_type not in ('居家','喘息','居家+喘息') then
    raise exception '服務類別格式不正確';
  end if;
  if v_payment_method is not null
     and v_payment_method not in ('銀行匯款','超商繳款','現金繳費','不收費') then
    raise exception '繳款方式格式不正確';
  end if;
  if v_welfare_identity='低收入戶' then
    v_payment_method:='不收費';
  elsif v_welfare_identity in ('中低收入戶','一般戶') and v_payment_method='不收費' then
    raise exception '第二類／第三類個案不可設定為不收費';
  end if;

  select s.id,s.role into v_staff_id,v_staff_role
  from public.staff_users s
  where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
    and s.is_active=true
  limit 1;

  if v_staff_id is null then raise exception '找不到目前登入的內部人員資料'; end if;

  if v_staff_role='supervisor' then
    v_supervisor:=v_staff_id;
  end if;

  if v_supervisor is null then raise exception '負責督導為必填'; end if;
  if not exists(
    select 1 from public.staff_users s
    where s.id=v_supervisor and s.is_active=true and s.can_supervise=true
  ) then
    raise exception '所選人員目前不是可指派的督導';
  end if;

  if v_national_id<>'' then
    select c.id,c.case_no,c.supervisor_id
      into v_case_id,v_existing_case_no,v_existing_supervisor
    from public.care_cases c
    where upper(btrim(coalesce(c.national_id,'')))=v_national_id
    limit 1;
  end if;

  if v_case_id is null and v_match_case is not null then
    select c.id,c.case_no,c.supervisor_id
      into v_case_id,v_existing_case_no,v_existing_supervisor
    from public.care_cases c
    where c.id=v_match_case;
  end if;

  if v_case_id is not null then
    if not private.can_edit_case(v_existing_supervisor) then
      raise exception '此個案由其他督導負責，目前帳號僅能查閱，不能更新';
    end if;

    if coalesce(btrim(v_existing_case_no),'')<>'' and upper(btrim(v_existing_case_no))<>v_case_no then
      raise exception '個案編號與既有資料不一致';
    end if;

    if v_hash is not null and exists(
      select 1 from public.case_imports ci
      where ci.case_id=v_case_id and ci.source_hash=v_hash
    ) then
      return jsonb_build_object(
        'action','duplicate',
        'case_id',v_case_id,
        'case_no',coalesce(v_existing_case_no,v_case_no)
      );
    end if;

    update public.care_cases
    set service_usage_type=v_service_usage_type,
        payment_method=v_payment_method,
        lives_alone=case when payload ? 'lives_alone' and nullif(payload->>'lives_alone','') is not null then (payload->>'lives_alone')::boolean else lives_alone end,
        has_dementia=case when payload ? 'has_dementia' and nullif(payload->>'has_dementia','') is not null then (payload->>'has_dementia')::boolean else has_dementia end,
        import_source='html',
        imported_at=now(),
        updated_at=now()
    where id=v_case_id;

    v_action:='updated';
  else
    if not (payload ? 'lives_alone') or nullif(payload->>'lives_alone','') is null then
      raise exception '獨居狀態為必填';
    end if;
    if not (payload ? 'has_dementia') or nullif(payload->>'has_dementia','') is null then
      raise exception '失智狀態為必填';
    end if;
    if nullif(payload->>'open_date','') is null then
      raise exception '新增個案須填寫開案日期';
    end if;
    if nullif(btrim(payload->>'google_maps_url'),'') is not null and not (btrim(payload->>'google_maps_url') ~ '^https://((www\.)?google\.com/maps([/?#]|$)|maps\.google\.com/|maps\.app\.goo\.gl/|goo\.gl/maps([/?#]|$))') then
      raise exception '請輸入有效的 Google Maps 連結';
    end if;

    if exists(
      select 1 from public.care_cases c
      where upper(btrim(coalesce(c.case_no,'')))=v_case_no
    ) then
      raise exception '此個案編號已存在';
    end if;

    insert into public.care_cases(
      case_no,case_name,national_id,birth_date,gender,address,phone,lives_alone,has_dementia,
      cms_level,identity_type,has_disability,is_indigenous,indigenous_group,welfare_identity,copay_rate,assessment_date,plan_approval_date,a_unit_name,
      case_manager_name,case_manager_phone,assessor_name,current_plan_date,
      service_usage_type,payment_method,
      supervisor_id,service_status,import_source,imported_at,created_by,open_date,google_maps_url
    ) values (
      v_case_no,
      nullif(payload->>'case_name',''),
      nullif(v_national_id,''),
      nullif(payload->>'birth_date','')::date,
      nullif(payload->>'gender',''),
      nullif(payload->>'address',''),
      nullif(payload->>'phone',''),
      (payload->>'lives_alone')::boolean,
      (payload->>'has_dementia')::boolean,
      nullif(payload->>'cms_level',''),
      nullif(payload->>'identity_type',''),
      case when payload ? 'has_disability' and nullif(payload->>'has_disability','') is not null then (payload->>'has_disability')::boolean else null end,
      case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null then (payload->>'is_indigenous')::boolean else null end,
      case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null and (payload->>'is_indigenous')::boolean=false then null else nullif(payload->>'indigenous_group','') end,
      nullif(payload->>'welfare_identity',''),
      case nullif(payload->>'welfare_identity','') when '一般戶' then 16 when '中低收入戶' then 5 when '低收入戶' then 0 else nullif(payload->>'copay_rate','')::numeric end,
      nullif(payload->>'assessment_date','')::date,
      nullif(payload->>'plan_approval_date','')::date,
      nullif(payload->>'a_unit_name',''),
      nullif(payload->>'case_manager_name',''),
      nullif(payload->>'case_manager_phone',''),
      nullif(payload->>'assessor_name',''),
      nullif(v_plan->>'plan_date','')::date,
      v_service_usage_type,v_payment_method,
      v_supervisor,'active','html',now(),(select auth.uid()),nullif(payload->>'open_date','')::date,nullif(btrim(payload->>'google_maps_url'),'')
    ) returning id into v_case_id;

    insert into public.case_supervisor_assignments(
      case_id,supervisor_id,assigned_from,is_current,created_by
    ) values(
      v_case_id,v_supervisor,current_date,true,(select auth.uid())
    );

    v_action:='created';
  end if;

  v_import_id:=gen_random_uuid();

  insert into public.case_imports(
    id,case_id,file_name,storage_path,source_ca110_id,source_hash,imported_by,
    detected_plan_date,import_type,status,warnings,parsed_data
  ) values(
    v_import_id,v_case_id,coalesce(nullif(payload->>'file_name',''),'import.html'),
    coalesce(nullif(payload->>'storage_path',''),''),
    nullif(payload->>'source_ca110_id',''),v_hash,(select auth.uid()),
    nullif(v_plan->>'plan_date','')::date,
    case when v_action='created' then 'new_case' else 'update_case' end,
    'success',coalesce(payload->'warnings','[]'::jsonb),
    payload - 'raw_html'
  );

  if jsonb_typeof(v_plan)='object'
     and (
       btrim(coalesce(v_plan->>'raw_plan_text',''))<>''
       or coalesce(v_plan->'sections','{}'::jsonb)<>'{}'::jsonb
       or nullif(v_plan->>'plan_date','') is not null
       or (jsonb_typeof(v_services)='array' and jsonb_array_length(v_services)>0)
       or (jsonb_typeof(v_budgets)='array' and jsonb_array_length(v_budgets)>0)
     ) then
    insert into public.care_plans(
      case_id,plan_date,phone_contact_date,home_visit_date,visit_with,sections,
      raw_plan_text,a_unit_name,case_manager_name,is_current,source_import_id,
      updated_at,updated_by
    ) values(
      v_case_id,
      nullif(v_plan->>'plan_date','')::date,
      nullif(v_plan->>'phone_contact_date','')::date,
      nullif(v_plan->>'home_visit_date','')::date,
      nullif(v_plan->>'visit_with',''),
      coalesce(v_plan->'sections','{}'::jsonb),
      nullif(v_plan->>'raw_plan_text',''),
      nullif(payload->>'a_unit_name',''),
      nullif(payload->>'case_manager_name',''),
      false,v_import_id,now(),(select auth.uid())
    ) returning id into v_plan_id;
  end if;

  if jsonb_typeof(v_services)='array' then
    for item in select value from jsonb_array_elements(v_services)
    loop
      if btrim(coalesce(item->>'service_code',''))<>'' then
        insert into public.case_approved_services(
          case_id,care_plan_id,service_group,service_code,service_name,unit_price,
          approved_quantity,subtotal,valid_from,valid_to,is_current,source_import_id
        ) values(
          v_case_id,v_plan_id,nullif(item->>'service_group',''),
          upper(btrim(item->>'service_code')),nullif(item->>'service_name',''),
          nullif(item->>'unit_price','')::numeric,
          nullif(item->>'approved_quantity','')::numeric,
          nullif(item->>'subtotal','')::numeric,
          nullif(item->>'valid_from','')::date,
          nullif(item->>'valid_to','')::date,
          false,v_import_id
        );
      end if;
    end loop;
  end if;

  if jsonb_typeof(v_budgets)='array' then
    for item in select value from jsonb_array_elements(v_budgets)
    loop
      if btrim(coalesce(item->>'category',''))<>'' then
        insert into public.service_budgets(
          case_id,care_plan_id,category,benefit_limit,planned_total,remaining_amount,
          valid_from,valid_to,is_current,source_import_id
        ) values(
          v_case_id,v_plan_id,item->>'category',
          nullif(item->>'benefit_limit','')::numeric,
          nullif(item->>'planned_total','')::numeric,
          nullif(item->>'remaining_amount','')::numeric,
          nullif(item->>'valid_from','')::date,
          nullif(item->>'valid_to','')::date,
          false,v_import_id
        );
      end if;
    end loop;
  end if;

  v_current_plan_id:=private.refresh_case_plan_current(v_case_id);
  v_import_is_current:=(v_plan_id is not null and v_current_plan_id=v_plan_id);

  if v_action='created' or v_import_is_current then
    update public.care_cases c set
      case_no=coalesce(nullif(c.case_no,''),v_case_no),
      case_name=coalesce(nullif(payload->>'case_name',''),c.case_name),
      national_id=case when v_national_id<>'' then v_national_id else c.national_id end,
      birth_date=coalesce(nullif(payload->>'birth_date','')::date,c.birth_date),
      gender=coalesce(nullif(payload->>'gender',''),c.gender),
      address=coalesce(nullif(payload->>'address',''),c.address),
      phone=coalesce(nullif(payload->>'phone',''),c.phone),
      lives_alone=case when payload ? 'lives_alone' then (payload->>'lives_alone')::boolean else c.lives_alone end,
      cms_level=coalesce(nullif(payload->>'cms_level',''),c.cms_level),
      identity_type=coalesce(nullif(payload->>'identity_type',''),c.identity_type),
      has_disability=case when payload ? 'has_disability' and nullif(payload->>'has_disability','') is not null then (payload->>'has_disability')::boolean else c.has_disability end,
      is_indigenous=case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null then (payload->>'is_indigenous')::boolean else c.is_indigenous end,
      indigenous_group=case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null and (payload->>'is_indigenous')::boolean=false then null else coalesce(nullif(payload->>'indigenous_group',''),c.indigenous_group) end,
      welfare_identity=coalesce(nullif(payload->>'welfare_identity',''),c.welfare_identity),
      has_dementia=case when payload ? 'has_dementia' and nullif(payload->>'has_dementia','') is not null then (payload->>'has_dementia')::boolean else c.has_dementia end,
      copay_rate=case nullif(payload->>'welfare_identity','') when '一般戶' then 16 when '中低收入戶' then 5 when '低收入戶' then 0 else coalesce(nullif(payload->>'copay_rate','')::numeric,c.copay_rate) end,
      assessment_date=coalesce(nullif(payload->>'assessment_date','')::date,c.assessment_date),
      plan_approval_date=coalesce(nullif(payload->>'plan_approval_date','')::date,c.plan_approval_date),
      a_unit_name=coalesce(nullif(payload->>'a_unit_name',''),c.a_unit_name),
      case_manager_name=coalesce(nullif(payload->>'case_manager_name',''),c.case_manager_name),
      case_manager_phone=coalesce(nullif(payload->>'case_manager_phone',''),c.case_manager_phone),
      assessor_name=coalesce(nullif(payload->>'assessor_name',''),c.assessor_name),
      updated_at=now()
    where c.id=v_case_id;

    if jsonb_typeof(v_contacts) <> 'array' then
      raise exception '匯入聯絡人格式不正確';
    end if;

    -- 此段只同步 html_import 來源；不變動手動建立聯絡人的 ID。
    -- 清除匯入來源的舊主要聯絡人標記，避免部分唯一索引衝突。
    update public.case_contacts
       set is_primary_contact=false,updated_at=now()
     where case_id=v_case_id and source='html_import' and is_primary_contact;

    for item in select value from jsonb_array_elements(v_contacts) loop
      if btrim(coalesce(item->>'contact_name',''))<>'' then
        -- 同姓名內先比對關係、電話；一次匯入每筆既有 ID 僅對應一筆。
        v_import_contact_id:=null;
        select cc.id into v_import_contact_id
          from public.case_contacts cc
         where cc.case_id=v_case_id
           and cc.source='html_import'
           and cc.contact_name=btrim(item->>'contact_name')
           and not (cc.id=any(v_import_keep_ids))
         order by
           (coalesce(cc.relationship,'')=coalesce(nullif(btrim(item->>'relationship'),''),'')) desc,
           (coalesce(cc.phone,'')=coalesce(nullif(btrim(item->>'phone'),''),'')) desc,
           cc.created_at,cc.id
         limit 1;

        if v_import_contact_id is not null then
          update public.case_contacts cc
             set contact_name=btrim(item->>'contact_name'),
                 relationship=nullif(btrim(item->>'relationship'),''),
                 phone=nullif(btrim(item->>'phone'),''),
                 is_primary_contact=(
                   coalesce(item->>'is_primary_contact','false')='true'
                   and not exists (
                     select 1 from public.case_contacts other
                      where other.case_id=v_case_id and other.is_primary_contact
                        and other.id<>v_import_contact_id
                   )
                 ),
                 is_primary_caregiver=coalesce(item->>'is_primary_caregiver','false')='true',
                 is_secondary_caregiver=coalesce(item->>'is_secondary_caregiver','false')='true',
                 notes=nullif(btrim(item->>'notes'),''),
                 source_import_id=v_import_id,
                 updated_at=now()
           where cc.id=v_import_contact_id and cc.case_id=v_case_id;
        else
          insert into public.case_contacts(
            case_id,contact_name,relationship,phone,is_primary_contact,
            is_primary_caregiver,is_secondary_caregiver,notes,source,source_import_id
          ) values(
            v_case_id,btrim(item->>'contact_name'),
            nullif(btrim(item->>'relationship'),''),
            nullif(btrim(item->>'phone'),''),
            (
              coalesce(item->>'is_primary_contact','false')='true'
              and not exists (
                select 1 from public.case_contacts pc
                 where pc.case_id=v_case_id and pc.is_primary_contact
              )
            ),
            coalesce(item->>'is_primary_caregiver','false')='true',
            coalesce(item->>'is_secondary_caregiver','false')='true',
            nullif(btrim(item->>'notes'),''),'html_import',v_import_id
          ) returning id into v_import_contact_id;
        end if;
        v_import_keep_ids:=array_append(v_import_keep_ids,v_import_contact_id);
      end if;
    end loop;

    if exists (
      select 1 from public.case_contacts cc
       where cc.case_id=v_case_id and cc.source='html_import'
         and not (cc.id=any(v_import_keep_ids))
         and exists (
           select 1 from public.case_contact_record_people rp
            where rp.case_contact_id=cc.id
         )
    ) then
      raise exception '匯入聯絡人已被家訪／電訪紀錄引用，無法刪除；請先核對既有聯絡人資料';
    end if;

    delete from public.case_contacts cc
     where cc.case_id=v_case_id and cc.source='html_import'
       and not (cc.id=any(v_import_keep_ids));
  end if;

  return jsonb_build_object(
    'action',v_action,
    'case_id',v_case_id,
    'case_no',v_case_no,
    'care_plan_id',v_plan_id,
    'import_id',v_import_id,
    'current_plan_id',v_current_plan_id,
    'plan_is_current',v_import_is_current
  );
end;
$function$
;
