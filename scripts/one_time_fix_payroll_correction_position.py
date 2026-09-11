from pathlib import Path
import re

repo = Path('.')
pc_path = repo / 'v52/payroll-correction-patch.txt'
calc_path = repo / 'v52/overtime-payroll-calc-patch.txt'
pc = pc_path.read_text(encoding='utf-8')
calc = calc_path.read_text(encoding='utf-8')

old_select = ".select('id,settlement_id,staff_id,staff_name,staff_role,adjustment_type,adjustment_minutes,reason,created_by,created_by_name,created_at')"
new_select = ".select('id,settlement_id,staff_id,staff_name,staff_role,adjustment_type,adjustment_minutes,reason,created_by,created_by_name,created_at,work_date,workday_type,start_time,end_time,day_offset_minutes,calculated_amount,wage_base_snapshot,agreed_daily_hours_snapshot,hourly_base_snapshot,rate_effective_from_snapshot,calculation_formula,calculation_version')"
if old_select not in pc:
    raise SystemExit('correction select anchor not found')
pc = pc.replace(old_select, new_select, 1)

old_duration = '<div class="field"><label>更正時數 *</label><div class="ot-time-pair"><input id="pcHours" type="number" min="0" max="999" step="1" value="0"><select id="pcMinutes">${pcMinuteOptions(\'overtime_pay\')}</select></div><div id="pcMinuteHelp" class="help">加班計薪／換休取得以10分鐘為間隔。</div></div>'
new_duration = '<div id="pcDurationField" class="field"><label>更正時數 *</label><div class="ot-time-pair"><input id="pcHours" type="number" min="0" max="999" step="1" value="0"><select id="pcMinutes">${pcMinuteOptions(\'overtime_pay\')}</select></div><div id="pcMinuteHelp" class="help">換休取得以10分鐘為間隔；換休使用以30分鐘為間隔。</div></div>'
if old_duration not in pc:
    raise SystemExit('duration field anchor not found')
pc = pc.replace(old_duration, new_duration, 1)

old_reason = '<div class="field full"><label>更正原因 *</label><textarea id="pcReason" placeholder="例如：薪資結算後發現加班漏列30分鐘"></textarea></div>'
new_reason = '''<div id="pcOvertimeMeta" class="field full hidden">
            <div class="form-grid">
              <div class="field"><label>加班日期 *</label><input id="pcCorrDate" type="date"></div>
              <div class="field"><label>出勤類型 *</label><select id="pcCorrDayType"><option value="overtime">平日加班</option><option value="rest_day_overtime">休息日加班</option><option value="national_holiday_overtime">國定假日出勤</option></select></div>
              <div class="field"><label>開始時間 *</label><div class="ot-time-pair"><select id="pcCorrStartHour">${pcHourOptions()}</select><select id="pcCorrStartMinute">${pcTenMinuteOptions()}</select></div></div>
              <div class="field"><label>結束時間 *</label><div class="ot-time-pair"><select id="pcCorrEndHour">${pcHourOptions()}</select><select id="pcCorrEndMinute">${pcTenMinuteOptions()}</select></div></div>
            </div>
            <div id="pcCorrCalc" class="ot-calc" style="margin-top:8px">請填寫實際加班日期與起訖時間，系統會依同日實際加班順位試算。</div>
            <div class="help" style="margin-top:6px">加班計薪更正以10分鐘為間隔；跨午夜請自行拆成兩筆。補發區間不可與既有已認列加班重疊，扣回區間必須是已認列領加班費的時段。</div>
          </div>
          <div class="field full"><label>更正原因 *</label><textarea id="pcReason" placeholder="例如：薪資結算後發現22:00～22:30加班漏列"></textarea></div>'''
if old_reason not in pc:
    raise SystemExit('reason field anchor not found')
pc = pc.replace(old_reason, new_reason, 1)

helper = r'''
  function pcHourOptions(selected=''){
    let html='<option value="">時</option>';
    for(let i=0;i<24;i++){
      const v=String(i).padStart(2,'0');
      html+=`<option value="${v}" ${v===selected?'selected':''}>${v}</option>`;
    }
    return html;
  }

  function pcTenMinuteOptions(selected='00'){
    return ['00','10','20','30','40','50'].map(v=>`<option value="${v}" ${v===selected?'selected':''}>${v}</option>`).join('');
  }

  function pcSelectedTime(prefix){
    const h=document.getElementById(prefix+'Hour')?.value||'';
    const m=document.getElementById(prefix+'Minute')?.value||'';
    return h&&m?`${h}:${m}`:null;
  }

  function pcMinutesBetween(start,end){
    if(!start||!end)return 0;
    const [sh,sm]=start.split(':').map(Number),[eh,em]=end.split(':').map(Number);
    const a=sh*60+sm,b=eh*60+em;
    if(b===0&&a>0)return 1440-a;
    return b>a?b-a:0;
  }

  function pcCrossesMidnight(start,end){
    if(!start||!end)return false;
    const [sh,sm]=start.split(':').map(Number),[eh,em]=end.split(':').map(Number);
    const a=sh*60+sm,b=eh*60+em;
    return b<a&&b!==0;
  }

  function pcMoney(value){
    const n=Number(value);
    return Number.isFinite(n)?`NT$ ${n.toLocaleString('zh-TW',{minimumFractionDigits:2,maximumFractionDigits:2})}`:'—';
  }

  function pcWorkdayLabel(type){
    return ({overtime:'平日加班',rest_day_overtime:'休息日加班',national_holiday_overtime:'國定假日出勤'})[type]||type||'—';
  }

  async function pcPreviewOvertimeCorrection(showError=false){
    const box=document.getElementById('pcCorrCalc');
    const settlement=pcSettlement();
    const staffId=document.getElementById('pcStaff')?.value;
    const date=document.getElementById('pcCorrDate')?.value;
    const dayType=document.getElementById('pcCorrDayType')?.value;
    const direction=Number(document.getElementById('pcDirection')?.value||1);
    const start=pcSelectedTime('pcCorrStart'),end=pcSelectedTime('pcCorrEnd');
    if(!settlement||!staffId||!date||!dayType||!start||!end){
      if(box)box.textContent='請填寫實際加班日期與起訖時間，系統會依同日實際加班順位試算。';
      return null;
    }
    if(pcCrossesMidnight(start,end)){
      if(box)box.textContent='跨午夜更正不可用一筆建立，請自行分成兩筆。';
      if(showError)toast('跨午夜更正請自行分成兩筆','warn');
      return null;
    }
    if(pcMinutesBetween(start,end)<=0){
      if(box)box.textContent='結束時間必須晚於開始時間；結束00:00視同當日24:00。';
      return null;
    }
    const {data,error}=await db.rpc('preview_payroll_overtime_correction',{
      p_settlement_id:settlement.id,p_staff_id:staffId,p_work_date:date,p_workday_type:dayType,
      p_start_time:start,p_end_time:end,p_direction:direction
    });
    if(error){
      if(box)box.textContent='無法試算：'+(error.message||error);
      if(showError)toast('無法建立加班計薪更正：'+(error.message||error),'warn');
      return null;
    }
    const row=Array.isArray(data)?data[0]:data;
    if(!row)return null;
    const endPos=Number(row.day_offset_minutes||0)+Number(row.correction_minutes||0);
    if(box)box.innerHTML=`自動計算：<strong>${escapeHTML(pcDuration(row.correction_minutes))}</strong>｜同日倍率順位第 ${Number(row.day_offset_minutes||0)+1}–${endPos} 分鐘｜預估更正金額 <strong>${escapeHTML(pcMoney(row.calculated_amount))}</strong>`;
    return row;
  }

  function pcRefreshCorrectionMode(){
    const type=document.getElementById('pcType')?.value;
    const durationField=document.getElementById('pcDurationField');
    const overtimeMeta=document.getElementById('pcOvertimeMeta');
    const isOvertime=type==='overtime_pay';
    durationField?.classList.toggle('hidden',isOvertime);
    overtimeMeta?.classList.toggle('hidden',!isOvertime);
    if(isOvertime)pcPreviewOvertimeCorrection(false);
  }

'''
anchor = '  function pcOpenCorrectionModal(){'
if anchor not in pc:
    raise SystemExit('pcOpenCorrectionModal anchor not found')
pc = pc.replace(anchor, helper + anchor, 1)

old_listener = r'''    document.getElementById('pcType')?.addEventListener('change',()=>{
      const type=document.getElementById('pcType').value;
      const min=document.getElementById('pcMinutes');
      min.innerHTML=pcMinuteOptions(type,'00');
      document.getElementById('pcMinuteHelp').textContent=type==='comp_leave_used'
        ? '換休使用以30分鐘為間隔。'
        : '加班計薪／換休取得以10分鐘為間隔。';
    });'''
new_listener = r'''    const pcRefresh=()=>{
      const type=document.getElementById('pcType')?.value;
      const min=document.getElementById('pcMinutes');
      if(min)min.innerHTML=pcMinuteOptions(type,'00');
      const help=document.getElementById('pcMinuteHelp');
      if(help)help.textContent=type==='comp_leave_used'?'換休使用以30分鐘為間隔。':'換休取得以10分鐘為間隔。';
      pcRefreshCorrectionMode();
    };
    document.getElementById('pcType')?.addEventListener('change',pcRefresh);
    ['pcStaff','pcDirection','pcCorrDate','pcCorrDayType','pcCorrStartHour','pcCorrStartMinute','pcCorrEndHour','pcCorrEndMinute'].forEach(id=>{
      document.getElementById(id)?.addEventListener('change',()=>pcPreviewOvertimeCorrection(false));
    });
    pcRefresh();'''
if old_listener not in pc:
    raise SystemExit('type listener anchor not found')
pc = pc.replace(old_listener, new_listener, 1)

new_submit = r'''  async function pcSubmitCorrection(){
    const settlement=pcSettlement();
    if(!settlement){toast('找不到本月份的月結資料','error');return false;}

    const staffId=document.getElementById('pcStaff')?.value;
    const staff=(state.overtimeStaffDirectory||[]).find(s=>String(s.id)===String(staffId));
    const type=document.getElementById('pcType')?.value;
    const direction=Number(document.getElementById('pcDirection')?.value||1);
    const reason=String(document.getElementById('pcReason')?.value||'').trim();

    if(!staff){toast('請選擇員工','warn');return false;}
    if(!['overtime_pay','comp_leave_earned','comp_leave_used'].includes(type)){toast('請選擇更正項目','warn');return false;}
    if(!reason){toast('請填寫更正原因','warn');return false;}

    let payload={
      settlement_id:settlement.id,staff_id:staff.id,staff_name:staff.display_name,staff_role:staff.role,
      adjustment_type:type,reason,created_by:state.user.id,created_by_name:state.profile.display_name
    };
    let confirmText='';

    if(type==='overtime_pay'){
      const date=document.getElementById('pcCorrDate')?.value;
      const dayType=document.getElementById('pcCorrDayType')?.value;
      const start=pcSelectedTime('pcCorrStart'),end=pcSelectedTime('pcCorrEnd');
      const {start:monthStart,end:monthEnd}=(()=>{const m=String(state.overtimeMonth||'');const [y,mo]=m.split('-').map(Number);return {start:`${m}-01`,end:isoDate(new Date(y,mo,0))};})();
      if(!date||!dayType||!start||!end){toast('請完整填寫加班日期、出勤類型與起訖時間','warn');return false;}
      if(date<monthStart||date>monthEnd){toast('加班計薪更正日期必須屬於目前月結月份','warn');return false;}
      const preview=await pcPreviewOvertimeCorrection(true);
      if(!preview)return false;
      const total=Number(preview.correction_minutes||0)*direction;
      payload={...payload,adjustment_minutes:total,work_date:date,workday_type:dayType,start_time:start,end_time:end};
      confirmText=`確定建立這筆月結更正嗎？\n\n${staff.display_name}｜${pcWorkdayLabel(dayType)}｜${start}～${end==='00:00'?'24:00':end}\n${direction>0?'補發':'扣回'} ${pcDuration(Math.abs(total))}｜${pcMoney(preview.calculated_amount)}\n倍率順位：同日第 ${Number(preview.day_offset_minutes||0)+1}–${Number(preview.day_offset_minutes||0)+Number(preview.correction_minutes||0)} 分鐘\n\n建立後不可直接修改或刪除。`;
    }else{
      const hours=Math.max(0,Number(document.getElementById('pcHours')?.value)||0);
      const minutes=Math.max(0,Number(document.getElementById('pcMinutes')?.value)||0);
      const total=(hours*60+minutes)*direction;
      if(total===0){toast('更正時數不可為0','warn');return false;}
      payload={...payload,adjustment_minutes:total};
      confirmText=`確定建立這筆月結更正嗎？\n\n${staff.display_name}｜${pcTypeLabel(type)}｜${direction>0?'+':'−'}${pcDuration(Math.abs(total))}\n\n建立後不可直接修改或刪除。`;
    }

    if(!confirm(confirmText))return false;
    showLoading(true);
    try{
      const {error}=await db.from('payroll_settlement_corrections').insert(payload);
      if(error)throw error;
      closeModal();
      state.payrollRatesLoaded=false;
      state.payrollCorrectionsLoaded=false;
      await pcLoadData(true);
      state.overtimeView='payroll';
      navigate('overtime');
      toast('月結更正單已建立','success');
      return true;
    }catch(err){
      console.error(err);
      toast('建立月結更正失敗：'+(err?.message||err),'error');
      return false;
    }finally{
      showLoading(false);
    }
  }

'''
pc, n = re.subn(r"  async function pcSubmitCorrection\(\)\{.*?\n  \}\n\n  function pcEnhance\(\)\{", new_submit + "  function pcEnhance(){", pc, count=1, flags=re.S)
if n != 1:
    raise SystemExit(f'pcSubmitCorrection replacement count={n}')

old_history = "<div class=\"pc-history-sub\">原因：${escapeHTML(c.reason)}<br>更正人：${escapeHTML(c.created_by_name||'—')}・${rocDate(c.created_at)}</div>"
new_history = "<div class=\"pc-history-sub\">${c.adjustment_type==='overtime_pay'&&c.work_date?`加班：${rocDate(String(c.work_date)+'T00:00:00')}・${escapeHTML(pcWorkdayLabel(c.workday_type))}・${escapeHTML(String(c.start_time||'').slice(0,5))}～${escapeHTML(String(c.end_time||'').slice(0,5)==='00:00'?'24:00':String(c.end_time||'').slice(0,5))}<br>金額：${escapeHTML(pcMoney(c.calculated_amount))}・倍率順位第 ${Number(c.day_offset_minutes||0)+1}–${Number(c.day_offset_minutes||0)+Math.abs(Number(c.adjustment_minutes)||0)} 分鐘<br>`:''}原因：${escapeHTML(c.reason)}<br>更正人：${escapeHTML(c.created_by_name||'—')}・${rocDate(c.created_at)}</div>"
if old_history not in pc:
    raise SystemExit('history anchor not found')
pc = pc.replace(old_history, new_history, 1)

# Disable the older payroll-calculation patch's correction modal and submit interception.
calc, n = re.subn(r"  function prEnhanceCorrectionModal\(\)\{.*?\n  \}\n\n  async function prSubmitCorrectionAmount", "  function prEnhanceCorrectionModal(){ return; }\n\n  async function prSubmitCorrectionAmount", calc, count=1, flags=re.S)
if n != 1:
    raise SystemExit(f'prEnhanceCorrectionModal replacement count={n}')

old_intercept = "    if(prCanReview()&&modal.querySelector('#pcType')&&document.getElementById('pcType')?.value==='overtime_pay'){\n      e.preventDefault();e.stopImmediatePropagation();prSubmitCorrectionAmount();\n    }"
if old_intercept not in calc:
    raise SystemExit('old correction intercept anchor not found')
calc = calc.replace(old_intercept, '', 1)

pc_path.write_text(pc, encoding='utf-8')
calc_path.write_text(calc, encoding='utf-8')
print('patched payroll correction actual-time workflow')
