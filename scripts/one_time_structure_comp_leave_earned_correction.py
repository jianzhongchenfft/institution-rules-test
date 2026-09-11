from pathlib import Path

p = Path('v52/payroll-correction-patch.txt')
s = p.read_text(encoding='utf-8')

s = s.replace(
"// V5.2 月結後更正單：只處理已月結報表的附加式更正\n// 本檔不再計算或覆寫「目前剩餘換休」，也不再攔截「使用換休」申請流程。",
"// V5.2 月結後更正單：已月結報表的附加式更正，換休取得同步實際換休帳本\n// 換休取得更正保存實際日期、來源與必要起訖時間；換休使用更正仍待下一階段結構化。",
1)

old = """  function pcWorkdayLabel(type){
    return ({overtime:'平日加班',rest_day_overtime:'休息日加班',national_holiday_overtime:'國定假日出勤'})[type]||type||'—';
  }"""
new = """  function pcWorkdayLabel(type){
    return ({overtime:'平日加班',rest_day_overtime:'休息日加班',national_holiday_overtime:'國定假日出勤',holiday_visit_comp:'假日家訪換休'})[type]||type||'—';
  }

  function pcEarnedSourceLabel(type){
    return ({overtime:'平日加班換休',rest_day_overtime:'休息日加班換休',national_holiday_overtime:'國定假日換休',holiday_visit_comp:'假日家訪換休'})[type]||type||'—';
  }

  function pcCorrectionMetaHTML(c){
    if(c.adjustment_type==='overtime_pay'&&c.work_date){
      return `加班：${rocDate(String(c.work_date)+'T00:00:00')}・${escapeHTML(pcWorkdayLabel(c.workday_type))}・${escapeHTML(String(c.start_time||'').slice(0,5))}～${escapeHTML(String(c.end_time||'').slice(0,5)==='00:00'?'24:00':String(c.end_time||'').slice(0,5))}<br>金額：${escapeHTML(pcMoney(c.calculated_amount))}・倍率順位第 ${Number(c.day_offset_minutes||0)+1}–${Number(c.day_offset_minutes||0)+Math.abs(Number(c.adjustment_minutes)||0)} 分鐘<br>`;
    }
    if(c.adjustment_type==='comp_leave_earned'&&c.work_date){
      if(c.workday_type==='holiday_visit_comp'){
        const cases=Math.max(1,Math.round(Math.abs(Number(c.adjustment_minutes)||0)/120));
        return `取得來源：${rocDate(String(c.work_date)+'T00:00:00')}・假日家訪換休・${cases}案×2小時・無到期限制<br>`;
      }
      const start=String(c.start_time||'').slice(0,5),end=String(c.end_time||'').slice(0,5)==='00:00'?'24:00':String(c.end_time||'').slice(0,5);
      const offset=Number(c.day_offset_minutes||0),mins=Math.abs(Number(c.adjustment_minutes)||0);
      return `取得來源：${rocDate(String(c.work_date)+'T00:00:00')}・${escapeHTML(pcEarnedSourceLabel(c.workday_type))}・${escapeHTML(start)}～${escapeHTML(end)}<br>原同日倍率順位第 ${offset+1}–${offset+mins} 分鐘；到期時依此來源資料折算<br>`;
    }
    return '';
  }"""
if old not in s:
    raise SystemExit('workday label anchor not found')
s = s.replace(old,new,1)

old = """  function pcRefreshCorrectionMode(){
    const type=document.getElementById('pcType')?.value;
    const durationField=document.getElementById('pcDurationField');
    const overtimeMeta=document.getElementById('pcOvertimeMeta');
    const isOvertime=type==='overtime_pay';
    durationField?.classList.toggle('hidden',isOvertime);
    overtimeMeta?.classList.toggle('hidden',!isOvertime);
    if(isOvertime)pcPreviewOvertimeCorrection(false);
  }"""
new = """  function pcRefreshEarnedMeta(){
    const source=document.getElementById('pcEarnSource')?.value;
    const timed=document.getElementById('pcEarnTimedFields');
    const visit=document.getElementById('pcEarnHolidayField');
    const calc=document.getElementById('pcEarnCalc');
    const isVisit=source==='holiday_visit_comp';
    timed?.classList.toggle('hidden',isVisit);
    visit?.classList.toggle('hidden',!isVisit);
    if(!calc)return;
    if(isVisit){
      const cases=Math.max(1,Number(document.getElementById('pcEarnCases')?.value)||1);
      calc.innerHTML=`自動取得：<strong>${escapeHTML(pcDuration(cases*120))}</strong>（${cases}案×2小時）｜無到期限制`;
      return;
    }
    const start=pcSelectedTime('pcEarnStart'),end=pcSelectedTime('pcEarnEnd');
    if(!start||!end){calc.textContent='請填寫實際加班起訖時間，系統會自動計算換休取得時數。';return;}
    if(pcCrossesMidnight(start,end)){calc.textContent='跨午夜換休取得更正不可用一筆建立，請自行分成兩筆。';return;}
    const mins=pcMinutesBetween(start,end);
    if(mins<=0){calc.textContent='結束時間必須晚於開始時間；結束00:00視同當日24:00。';return;}
    calc.innerHTML=`自動取得：<strong>${escapeHTML(pcDuration(mins))}</strong>｜建立時會檢查是否與既有加班重疊，並保存原同日倍率順位供日後到期折算。`;
  }

  function pcRefreshCorrectionMode(){
    const type=document.getElementById('pcType')?.value;
    const durationField=document.getElementById('pcDurationField');
    const overtimeMeta=document.getElementById('pcOvertimeMeta');
    const earnedMeta=document.getElementById('pcEarnedMeta');
    const isOvertime=type==='overtime_pay';
    const isEarned=type==='comp_leave_earned';
    durationField?.classList.toggle('hidden',isOvertime||isEarned);
    overtimeMeta?.classList.toggle('hidden',!isOvertime);
    earnedMeta?.classList.toggle('hidden',!isEarned);
    if(isOvertime)pcPreviewOvertimeCorrection(false);
    if(isEarned)pcRefreshEarnedMeta();
  }"""
if old not in s:
    raise SystemExit('refresh mode anchor not found')
s = s.replace(old,new,1)

anchor = """          <div class=\"field full\"><label>更正原因 *</label><textarea id=\"pcReason\" placeholder=\"例如：薪資結算後發現22:00～22:30加班漏列\"></textarea></div>"""
insert = """          <div id=\"pcEarnedMeta\" class=\"field full hidden\">
            <div class=\"form-grid\">
              <div class=\"field\"><label>實際取得日期 *</label><input id=\"pcEarnDate\" type=\"date\"></div>
              <div class=\"field\"><label>取得來源 *</label><select id=\"pcEarnSource\"><option value=\"overtime\">平日加班換休</option><option value=\"rest_day_overtime\">休息日加班換休</option><option value=\"national_holiday_overtime\">國定假日換休</option><option value=\"holiday_visit_comp\">假日家訪換休</option></select></div>
              <div id=\"pcEarnTimedFields\" class=\"field full\">
                <div class=\"form-grid\">
                  <div class=\"field\"><label>開始時間 *</label><div class=\"ot-time-pair\"><select id=\"pcEarnStartHour\">${pcHourOptions()}</select><select id=\"pcEarnStartMinute\">${pcTenMinuteOptions()}</select></div></div>
                  <div class=\"field\"><label>結束時間 *</label><div class=\"ot-time-pair\"><select id=\"pcEarnEndHour\">${pcHourOptions()}</select><select id=\"pcEarnEndMinute\">${pcTenMinuteOptions()}</select></div></div>
                </div>
              </div>
              <div id=\"pcEarnHolidayField\" class=\"field hidden\"><label>家訪個案數 *</label><select id=\"pcEarnCases\"><option value=\"1\">1案（2小時）</option><option value=\"2\">2案（4小時）</option><option value=\"3\">3案（6小時）</option><option value=\"4\">4案（8小時）</option></select></div>
            </div>
            <div id=\"pcEarnCalc\" class=\"ot-calc\" style=\"margin-top:8px\">請填寫實際取得日期、來源與必要時間。</div>
            <div class=\"help\" style=\"margin-top:6px\">一般加班換休以10分鐘為間隔並保存原同日倍率順位；假日家訪換休依1案2小時計算且無到期限制。跨午夜請自行拆成兩筆。</div>
          </div>
""" + anchor
if anchor not in s:
    raise SystemExit('modal reason anchor not found')
s = s.replace(anchor,insert,1)

old = """    const pcRefresh=()=>{
      const type=document.getElementById('pcType')?.value;
      const min=document.getElementById('pcMinutes');
      if(min)min.innerHTML=pcMinuteOptions(type,'00');
      const help=document.getElementById('pcMinuteHelp');
      if(help)help.textContent=type==='comp_leave_used'?'換休使用以30分鐘為間隔。':'換休取得以10分鐘為間隔。';
      pcRefreshCorrectionMode();
    };"""
new = """    const pcRefresh=()=>{
      const type=document.getElementById('pcType')?.value;
      const min=document.getElementById('pcMinutes');
      if(min)min.innerHTML=pcMinuteOptions(type,'00');
      const help=document.getElementById('pcMinuteHelp');
      if(help)help.textContent='換休使用以30分鐘為間隔。';
      pcRefreshCorrectionMode();
    };"""
if old not in s:
    raise SystemExit('local refresh anchor not found')
s = s.replace(old,new,1)

old = """    ['pcStaff','pcDirection','pcCorrDate','pcCorrDayType','pcCorrStartHour','pcCorrStartMinute','pcCorrEndHour','pcCorrEndMinute'].forEach(id=>{
      document.getElementById(id)?.addEventListener('change',()=>pcPreviewOvertimeCorrection(false));
    });
    pcRefresh();"""
new = """    ['pcStaff','pcDirection','pcCorrDate','pcCorrDayType','pcCorrStartHour','pcCorrStartMinute','pcCorrEndHour','pcCorrEndMinute'].forEach(id=>{
      document.getElementById(id)?.addEventListener('change',()=>pcPreviewOvertimeCorrection(false));
    });
    ['pcEarnDate','pcEarnSource','pcEarnStartHour','pcEarnStartMinute','pcEarnEndHour','pcEarnEndMinute','pcEarnCases'].forEach(id=>{
      document.getElementById(id)?.addEventListener('change',pcRefreshEarnedMeta);
    });
    pcRefresh();"""
if old not in s:
    raise SystemExit('event listener anchor not found')
s = s.replace(old,new,1)

old = """    }else{
      const hours=Math.max(0,Number(document.getElementById('pcHours')?.value)||0);
      const minutes=Math.max(0,Number(document.getElementById('pcMinutes')?.value)||0);
      const total=(hours*60+minutes)*direction;
      if(total===0){toast('更正時數不可為0','warn');return false;}
      payload={...payload,adjustment_minutes:total};
      confirmText=`確定建立這筆月結更正嗎？

${staff.display_name}｜${pcTypeLabel(type)}｜${direction>0?'+':'−'}${pcDuration(Math.abs(total))}

建立後不可直接修改或刪除。`;
    }"""
new = """    }else if(type==='comp_leave_earned'){
      const date=document.getElementById('pcEarnDate')?.value;
      const source=document.getElementById('pcEarnSource')?.value;
      const {start:monthStart,end:monthEnd}=(()=>{const m=String(state.overtimeMonth||'');const [y,mo]=m.split('-').map(Number);return {start:`${m}-01`,end:isoDate(new Date(y,mo,0))};})();
      if(!date||!source){toast('請填寫實際取得日期與取得來源','warn');return false;}
      if(date<monthStart||date>monthEnd){toast('換休取得日期必須屬於目前月結月份','warn');return false;}
      if(source==='holiday_visit_comp'){
        const cases=Math.max(1,Math.min(4,Number(document.getElementById('pcEarnCases')?.value)||1));
        const total=cases*120*direction;
        payload={...payload,adjustment_minutes:total,work_date:date,workday_type:source,start_time:null,end_time:null};
        confirmText=`確定建立這筆月結更正嗎？

${staff.display_name}｜假日家訪換休｜${rocDate(date+'T00:00:00')}
${direction>0?'增加':'減少'}認列 ${cases}案×2小時＝${pcDuration(Math.abs(total))}
此類換休無到期限制。

建立後不可直接修改或刪除。`;
      }else{
        const start=pcSelectedTime('pcEarnStart'),end=pcSelectedTime('pcEarnEnd');
        if(!start||!end){toast('請完整填寫換休取得的開始與結束時間','warn');return false;}
        if(pcCrossesMidnight(start,end)){toast('跨午夜換休取得更正請自行分成兩筆','warn');return false;}
        const mins=pcMinutesBetween(start,end);
        if(mins<=0){toast('結束時間必須晚於開始時間','warn');return false;}
        const total=mins*direction;
        payload={...payload,adjustment_minutes:total,work_date:date,workday_type:source,start_time:start,end_time:end};
        confirmText=`確定建立這筆月結更正嗎？

${staff.display_name}｜${pcEarnedSourceLabel(source)}｜${rocDate(date+'T00:00:00')}
${start}～${end==='00:00'?'24:00':end}｜${direction>0?'增加':'減少'}認列 ${pcDuration(mins)}
系統會保存原同日倍率順位，供日後換休到期未休折算。

建立後不可直接修改或刪除。`;
      }
    }else{
      const hours=Math.max(0,Number(document.getElementById('pcHours')?.value)||0);
      const minutes=Math.max(0,Number(document.getElementById('pcMinutes')?.value)||0);
      const total=(hours*60+minutes)*direction;
      if(total===0){toast('更正時數不可為0','warn');return false;}
      payload={...payload,adjustment_minutes:total};
      confirmText=`確定建立這筆月結更正嗎？

${staff.display_name}｜${pcTypeLabel(type)}｜${direction>0?'+':'−'}${pcDuration(Math.abs(total))}

建立後不可直接修改或刪除。`;
    }"""
if old not in s:
    raise SystemExit('submit else anchor not found')
s = s.replace(old,new,1)

old_fragment = """${c.adjustment_type==='overtime_pay'&&c.work_date?`加班：${rocDate(String(c.work_date)+'T00:00:00')}・${escapeHTML(pcWorkdayLabel(c.workday_type))}・${escapeHTML(String(c.start_time||'').slice(0,5))}～${escapeHTML(String(c.end_time||'').slice(0,5)==='00:00'?'24:00':String(c.end_time||'').slice(0,5))}<br>金額：${escapeHTML(pcMoney(c.calculated_amount))}・倍率順位第 ${Number(c.day_offset_minutes||0)+1}–${Number(c.day_offset_minutes||0)+Math.abs(Number(c.adjustment_minutes)||0)} 分鐘<br>`:''}"""
new_fragment = """${pcCorrectionMetaHTML(c)}"""
if old_fragment not in s:
    raise SystemExit('history metadata anchor not found')
s = s.replace(old_fragment,new_fragment,1)

p.write_text(s,encoding='utf-8')
