-- 個案管理雙排列表：使用既有開案日期，僅新增 Google 地圖連結；測試版 2026-10-10
-- 開案日期與 Google 定位於新案建檔時設定，後續 HTML 更新不得覆蓋。
ALTER TABLE public.care_cases ADD COLUMN IF NOT EXISTS google_maps_url text;
-- 舊資料若有多人被標為主要聯絡人，只取消後續重複標記，不刪除聯絡人資料。
WITH duplicate_primary AS (
  SELECT id,row_number() OVER (PARTITION BY case_id ORDER BY created_at,id) AS seq
  FROM public.case_contacts WHERE is_primary_contact
)
UPDATE public.case_contacts c SET is_primary_contact=false,updated_at=now()
FROM duplicate_primary d WHERE c.id=d.id AND d.seq>1;
CREATE UNIQUE INDEX IF NOT EXISTS case_contacts_one_primary_per_case
  ON public.case_contacts(case_id) WHERE is_primary_contact;

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
    if (select count(*) from jsonb_array_elements(v_contacts) x where x->>'is_primary_contact'='true' and btrim(coalesce(x->>'contact_name',''))<>'') > 1 then
      raise exception '每位個案只能指定一位主要聯絡人';
    end if;
    delete from public.case_contacts where case_id=v_case_id;
    if jsonb_typeof(v_contacts)='array' then
      for item in select value from jsonb_array_elements(v_contacts)
      loop
        if btrim(coalesce(item->>'contact_name',''))<>'' then
          insert into public.case_contacts(
            case_id,contact_name,relationship,phone,is_primary_contact,
            is_primary_caregiver,is_secondary_caregiver,notes,source,source_import_id
          ) values(
            v_case_id,btrim(item->>'contact_name'),
            nullif(btrim(item->>'relationship'),''),
            nullif(btrim(item->>'phone'),''),
            coalesce(item->>'is_primary_contact','false')='true',
            coalesce(item->>'is_primary_caregiver','false')='true',
            coalesce(item->>'is_secondary_caregiver','false')='true',
            nullif(btrim(item->>'notes'),''),
            'manual',null
          );
        end if;
      end loop;
    end if;
  end if;

  return jsonb_build_object('case_id',v_case_id,'updated',true);
end;
$function$;

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

    delete from public.case_contacts
    where case_id=v_case_id and source='html_import';

    if jsonb_typeof(v_contacts)='array' then
      for item in select value from jsonb_array_elements(v_contacts)
      loop
        if btrim(coalesce(item->>'contact_name',''))<>'' then
          insert into public.case_contacts(
            case_id,contact_name,relationship,phone,is_primary_contact,
            is_primary_caregiver,is_secondary_caregiver,notes,source,source_import_id
          ) values(
            v_case_id,btrim(item->>'contact_name'),nullif(btrim(item->>'relationship'),''),
            nullif(btrim(item->>'phone'),''),
            (coalesce(item->>'is_primary_contact','false')='true' and not exists(select 1 from public.case_contacts pc where pc.case_id=v_case_id and pc.is_primary_contact)),
            coalesce(item->>'is_primary_caregiver','false')='true',
            coalesce(item->>'is_secondary_caregiver','false')='true',
            nullif(btrim(item->>'notes'),''),
            'html_import',v_import_id
          );
        end if;
      end loop;
    end if;
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
$function$;

CREATE OR REPLACE FUNCTION public.create_case_profile(payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO ''
AS $function$
DECLARE
  v_case_id uuid;
  v_supervisor uuid := nullif(payload->>'supervisor_id','')::uuid;
  v_case_no text := upper(regexp_replace(btrim(coalesce(payload->>'case_no','')),'\s+','','g'));
  v_name text := btrim(coalesce(payload->>'case_name',''));
  v_usage text := nullif(payload->>'service_usage_type','');
  v_welfare text := nullif(payload->>'welfare_identity','');
  v_payment text := nullif(payload->>'payment_method','');
  v_contacts jsonb := coalesce(payload->'contacts','[]'::jsonb);
  item jsonb;
BEGIN
  IF (select auth.uid()) IS NULL OR NOT private.can_manage_cases() OR NOT private.can_edit_case(v_supervisor) THEN
    RAISE EXCEPTION '沒有建立此個案的權限';
  END IF;
  IF v_case_no='' OR v_name='' OR v_supervisor IS NULL OR v_usage NOT IN ('居家','喘息','居家+喘息') OR v_usage IS NULL THEN
    RAISE EXCEPTION '個案編號、姓名、負責督導及服務類別為必填';
  END IF;
  IF nullif(payload->>'open_date','') IS NULL THEN RAISE EXCEPTION '開案日期為必填'; END IF;
  IF nullif(payload->>'lives_alone','') IS NULL OR nullif(payload->>'has_dementia','') IS NULL THEN
    RAISE EXCEPTION '失智與獨居狀態為必填';
  END IF;
  IF nullif(btrim(payload->>'google_maps_url'),'') IS NOT NULL AND NOT (btrim(payload->>'google_maps_url') ~ '^https://((www\.)?google\.com/maps([/?#]|$)|maps\.google\.com/|maps\.app\.goo\.gl/|goo\.gl/maps([/?#]|$))') THEN
    RAISE EXCEPTION '請輸入有效的 Google Maps 連結';
  END IF;
  IF jsonb_typeof(v_contacts)<>'array' THEN RAISE EXCEPTION '聯絡人資料格式不正確'; END IF;
  IF (select count(*) from jsonb_array_elements(v_contacts) x where x->>'is_primary_contact'='true' and btrim(coalesce(x->>'contact_name',''))<>'') > 1 THEN
    RAISE EXCEPTION '每位個案只能指定一位主要聯絡人';
  END IF;
  IF NOT EXISTS (select 1 from public.staff_users s where s.id=v_supervisor and s.can_supervise=true and s.is_active=true) THEN
    RAISE EXCEPTION '所選人員不是可指派的督導';
  END IF;
  IF v_payment IS NOT NULL AND v_payment NOT IN ('銀行匯款','超商繳款','現金繳費','不收費') THEN
    RAISE EXCEPTION '繳款方式格式不正確';
  END IF;
  IF v_welfare='低收入戶' THEN v_payment:='不收費';
  ELSIF v_welfare IN ('中低收入戶','一般戶') AND v_payment='不收費' THEN
    RAISE EXCEPTION '第二類／第三類個案不可設定為不收費';
  END IF;
  INSERT INTO public.care_cases (
    case_no,case_name,supervisor_id,open_date,google_maps_url,service_status,created_by,
    national_id,birth_date,gender,address,phone,cms_level,lives_alone,has_dementia,
    has_disability,is_indigenous,indigenous_group,welfare_identity,copay_rate,
    case_manager_name,case_manager_phone,service_usage_type,payment_method
  ) VALUES (
    v_case_no,v_name,v_supervisor,(payload->>'open_date')::date,nullif(btrim(payload->>'google_maps_url'),''),
    'active',(select auth.uid()),nullif(upper(btrim(payload->>'national_id')),''),
    nullif(payload->>'birth_date','')::date,nullif(payload->>'gender',''),
    nullif(btrim(payload->>'address'),''),nullif(btrim(payload->>'phone'),''),
    nullif(btrim(payload->>'cms_level'),''),(payload->>'lives_alone')::boolean,(payload->>'has_dementia')::boolean,
    nullif(payload->>'has_disability','')::boolean,nullif(payload->>'is_indigenous','')::boolean,
    nullif(btrim(payload->>'indigenous_group'),''),v_welfare,
    CASE v_welfare WHEN '一般戶' THEN 16 WHEN '中低收入戶' THEN 5 WHEN '低收入戶' THEN 0 ELSE nullif(payload->>'copay_rate','')::numeric END,
    nullif(btrim(payload->>'case_manager_name'),''),nullif(btrim(payload->>'case_manager_phone'),''),
    v_usage,v_payment
  ) RETURNING id INTO v_case_id;
  INSERT INTO public.case_supervisor_assignments(case_id,supervisor_id,assigned_from,is_current,created_by)
  VALUES (v_case_id,v_supervisor,current_date,true,(select auth.uid()));
  FOR item IN SELECT value FROM jsonb_array_elements(v_contacts) LOOP
    IF btrim(coalesce(item->>'contact_name',''))<>'' THEN
      INSERT INTO public.case_contacts(case_id,contact_name,relationship,phone,is_primary_contact,is_primary_caregiver,is_secondary_caregiver,notes,source)
      VALUES (v_case_id,btrim(item->>'contact_name'),nullif(btrim(item->>'relationship'),''),
        nullif(btrim(item->>'phone'),''),coalesce(item->>'is_primary_contact','false')='true',
        coalesce(item->>'is_primary_caregiver','false')='true',coalesce(item->>'is_secondary_caregiver','false')='true',
        nullif(btrim(item->>'notes'),''),'manual');
    END IF;
  END LOOP;
  RETURN jsonb_build_object('case_id',v_case_id,'created',true);
END;
$function$;
REVOKE ALL ON FUNCTION public.create_case_profile(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_case_profile(jsonb) TO authenticated,service_role;
