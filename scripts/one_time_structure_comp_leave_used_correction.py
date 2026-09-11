from pathlib import Path
import re

path=Path('v52/payroll-correction-patch.txt')
s=path.read_text(encoding='utf-8')

old="// V5.2 月結後更正單：已月結報表的附加式更正，換休取得同步實際換休帳本\n// 換休取得更正保存實際日期、來源與必要起訖時間；換休使用更正仍待下一階段結構化。"
new="// V5.2 月結後更正單：已月結報表的附加式更正，換休取得／使用同步實際換休帳本\n// 換休取得與換休使用更正均保存實際日期與必要來源資料；換休使用以30分鐘為單位。"
assert old in s
s=s.replace(old,new,1)

old=".select('id,settlement_id,staff_id,staff_name,staff_role,adjustment_type,adjustment_minutes,reason,created_by,created_by_name,created_at,work_date,workday_type,start_time,end_time,day_offset_minutes,calculated_amount,wage_base_snapshot,agreed_daily_hours_snapshot,hourly_base_snapshot,rate_effective_from_snapshot,calculation_formula,calculation_version')"
new=".select('id,settlement_id,staff_id,staff_name,staff_role,adjustment_type,adjustment_minutes,reason,created_by,created_by_name,created_at,work_date,workday_type,start_time,end_time,day_offset_minutes,calculated_amount,wage_base_snapshot,agreed_daily_hours_snapshot,hourly_base_snapshot,rate_effective_from_snapshot,calculation_formula,calculation_version,related_source_type,related_source_id')"
assert old in s
s=s.replace(old,new,1)

old="""  function pcTenMinuteOptions(selected='00'){
    return ['00','10','20','30','40','50'].map(v=>`<option value=\"${v}\" ${v===selected?'selected':''}>${v}</option>`).join('');
  }
"""
new=old+"""
  function pcThirtyMinuteOptions(selected='00'){
    return ['00','30'].map(v=>`<option value=\"${v}\" ${v===selected?'selected':''}>${v}</option>`).join('');
  }
"""
assert old in s
s=s.replace(old,new,1)

anchor="""    return '';
  }

  async function pcPreviewOvertimeCorrection(showError=false){"""
insert="""    if(c.adjustment_type==='comp_leave_used'&&c.work_date){
      const start=String(c.start_time||'').slice(0,5),end=String(c.end_time||'').slice(0,5)==='00:00'?'24:00':String(c.end_time||'').slice(0,5);
      const action=Number(c.adjustment_minutes)>0?'補登使用':'減少認列並還原原扣抵來源';
      return `使用：${rocDate(String(c.work_date)+'T00:00:00')}・${escapeHTML(start)}～${escapeHTML(end)}<br>${escapeHTML(action)}<br>`;
    }
    return '';
  }

  async function pcPreviewOvertimeCorrection(showError=false){"""
assert anchor in s
s=s.replace(anchor,insert,1)

anchor="""  function pcRefreshEarnedMeta(){"""
preview="""  async function pcPreviewUsedCorrection(showError=false){
    const box=document.getElementById('pcUsedCalc');
    const settlement=pcSettlement();
    const staffId=document.getElementById('pcStaff')?.value;
    const date=document.getElementById('pcUsedDate')?.value;
    const direction=Number(document.getElementById('pcDirection')?.value||1);
    const start=pcSelectedTime('pcUsedStart'),end=pcSelectedTime('pcUsedEnd');
    if(!settlement||!staffId||!date||!start||!end){
      if(box)box.textContent='請填寫實際使用日期與起訖時間，系統會自動計算時數並檢查換休帳本。';
      return null;
    }
    if(pcCrossesMidnight(start,end)){
      if(box)box.textContent='跨午夜換休使用更正不可用一筆建立，請自行分成兩筆。';
      if(showError)toast('跨午夜換休使用更正請自行分成兩筆','warn');
      return null;
    }
    const mins=pcMinutesBetween(start,end);
    if(mins<=0||mins%30!==0){
      if(box)box.textContent='換休使用更正須以30分鐘為單位，且結束時間必須晚於開始時間。';
      return null;
    }
    const {data,error}=await db.rpc('preview_payroll_comp_leave_used_correction',{
      p_settlement_id:settlement.id,p_staff_id:staffId,p_leave_date:date,
      p_start_time:start,p_end_time:end,p_direction:direction
    });
    if(error){
      if(box)box.textContent='無法試算：'+(error.message||error);
      if(showError)toast('無法建立換休使用更正：'+(error.message||error),'warn');
      return null;
    }
    const row=Array.isArray(data)?data[0]:data;
    if(!row)return null;
    if(direction>0){
      if(box)box.innerHTML=`自動計算：<strong>${escapeHTML(pcDuration(row.correction_minutes))}</strong>｜該日目前可扣抵換休 <strong>${escapeHTML(pcDuration(row.available_minutes))}</strong>`;
    }else{
      if(box)box.innerHTML=`將整筆還原：<strong>${escapeHTML(row.related_source_label||'既有換休使用紀錄')}</strong>｜${escapeHTML(pcDuration(row.correction_minutes))}`;
    }
    return row;
  }

"""+anchor
assert anchor in s
s=s.replace(anchor,preview,1)

pattern=re.compile(r"  function pcRefreshCorrectionMode\(\)\{.*?\n  \}\n\n  function pcOpenCorrectionModal\(\)\{",re.S)
replacement="""  function pcRefreshCorrectionMode(){
    const type=document.getElementById('pcType')?.value;
    const durationField=document.getElementById('pcDurationField');
    const overtimeMeta=document.getElementById('pcOvertimeMeta');
    const earnedMeta=document.getElementById('pcEarnedMeta');
    const usedMeta=document.getElementById('pcUsedMeta');
    const isOvertime=type==='overtime_pay';
    const isEarned=type==='comp_leave_earned';
    const isUsed=type==='comp_leave_used';
    durationField?.classList.toggle('hidden',isOvertime||isEarned||isUsed);
    overtimeMeta?.classList.toggle('hidden',!isOvertime);
    earnedMeta?.classList.toggle('hidden',!isEarned);
    usedMeta?.classList.toggle('hidden',!isUsed);
    if(isOvertime)pcPreviewOvertimeCorrection(false);
    if(isEarned)pcRefreshEarnedMeta();
    if(isUsed)pcPreviewUsedCorrection(false);
  }

  function pcOpenCorrectionModal(){"""
s,n=pattern.subn(replacement,s,count=1)
assert n==1

reason_anchor='''          <div class="field full"><label>更正原因 *</label><textarea id="pcReason" placeholder="例如：薪資結算後發現22:00～22:30加班漏列"></textarea></div>'''
used_block='''          <div id="pcUsedMeta" class="field full hidden">
            <div class="form-grid">
              <div class="field"><label>實際使用日期 *</label><input id="pcUsedDate" type="date"></div>
              <div class="field"><label>開始時間 *</label><div class="ot-time-pair"><select id="pcUsedStartHour">${pcHourOptions()}</select><select id="pcUsedStartMinute">${pcThirtyMinuteOptions()}</select></div></div>
              <div class="field"><label>結束時間 *</label><div class="ot-time-pair"><select id="pcUsedEndHour">${pcHourOptions()}</select><select id="pcUsedEndMinute">${pcThirtyMinuteOptions()}</select></div></div>
            </div>
            <div id="pcUsedCalc" class="ot-calc" style="margin-top:8px">請填寫實際使用日期與起訖時間，系統會自動計算時數並檢查換休帳本。</div>
            <div class="help" style="margin-top:6px">換休使用以30分鐘為單位。增加認列會依實際使用日扣抵當時可用換休；減少認列必須完整對應一筆既有換休使用。若只修正部分時數，請先整筆減少，再補登正確時段。</div>
          </div>
'''+reason_anchor
assert reason_anchor in s
s=s.replace(reason_anchor,used_block,1)

old="""    ['pcEarnDate','pcEarnSource','pcEarnStartHour','pcEarnStartMinute','pcEarnEndHour','pcEarnEndMinute','pcEarnCases'].forEach(id=>{
      document.getElementById(id)?.addEventListener('change',pcRefreshEarnedMeta);
    });
    pcRefresh();"""
new="""    ['pcEarnDate','pcEarnSource','pcEarnStartHour','pcEarnStartMinute','pcEarnEndHour','pcEarnEndMinute','pcEarnCases'].forEach(id=>{
      document.getElementById(id)?.addEventListener('change',pcRefreshEarnedMeta);
    });
    ['pcStaff','pcDirection','pcUsedDate','pcUsedStartHour','pcUsedStartMinute','pcUsedEndHour','pcUsedEndMinute'].forEach(id=>{
      document.getElementById(id)?.addEventListener('change',()=>pcPreviewUsedCorrection(false));
    });
    pcRefresh();"""
assert old in s
s=s.replace(old,new,1)

old="""    }else{
      const hours=Math.max(0,Number(document.getElementById('pcHours')?.value)||0);
      const minutes=Math.max(0,Number(document.getElementById('pcMinutes')?.value)||0);
      const total=(hours*60+minutes)*direction;
      if(total===0){toast('更正時數不可為0','warn');return false;}
      payload={...payload,adjustment_minutes:total};
      confirmText=`確定建立這筆月結更正嗎？\n\n${staff.display_name}｜${pcTypeLabel(type)}｜${direction>0?'+':'−'}${pcDuration(Math.abs(total))}\n\n建立後不可直接修改或刪除。`;
    }
"""
new="""    }else if(type==='comp_leave_used'){
      const date=document.getElementById('pcUsedDate')?.value;
      const start=pcSelectedTime('pcUsedStart'),end=pcSelectedTime('pcUsedEnd');
      const {start:monthStart,end:monthEnd}=(()=>{const m=String(state.overtimeMonth||'');const [y,mo]=m.split('-').map(Number);return {start:`${m}-01`,end:isoDate(new Date(y,mo,0))};})();
      if(!date||!start||!end){toast('請完整填寫實際使用日期與起訖時間','warn');return false;}
      if(date<monthStart||date>monthEnd){toast('換休使用日期必須屬於目前月結月份','warn');return false;}
      const preview=await pcPreviewUsedCorrection(true);
      if(!preview)return false;
      const total=Number(preview.correction_minutes||0)*direction;
      payload={...payload,adjustment_minutes:total,work_date:date,workday_type:'comp_leave_usage',start_time:start,end_time:end};
      confirmText=`確定建立這筆月結更正嗎？\n\n${staff.display_name}｜換休使用｜${rocDate(date+'T00:00:00')}\n${start}～${end==='00:00'?'24:00':end}｜${direction>0?'增加認列':'減少認列'} ${pcDuration(Math.abs(total))}${direction<0?`\n還原來源：${preview.related_source_label||'既有換休使用紀錄'}`:''}\n\n建立後不可直接修改或刪除。`;
    }else{
      toast('不支援的更正項目','warn');
      return false;
    }
"""
assert old in s
s=s.replace(old,new,1)

path.write_text(s,encoding='utf-8')
