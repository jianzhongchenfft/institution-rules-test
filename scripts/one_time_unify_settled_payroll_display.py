from pathlib import Path

summary_path = Path('v52/overtime-payroll-summary-patch.txt')
calc_path = Path('v52/overtime-payroll-calc-patch.txt')
summary = summary_path.read_text(encoding='utf-8')
calc = calc_path.read_text(encoding='utf-8')

# 1. Settled month corrections should be readable from either loader, deduplicated by id.
old = """  function correctionAmount(s,staffId=null){
    return (state.payrollAmountCorrections||[])
      .filter(c=>String(c.settlement_id)===String(s?.id)&&c.adjustment_type==='overtime_pay'&&(!staffId||String(c.staff_id)===String(staffId)))
      .reduce((sum,c)=>sum+(Number(c.calculated_amount)||0),0);
  }"""
new = """  function correctionAmount(s,staffId=null){
    const merged=new Map();
    [...(state.payrollCorrections||[]),...(state.payrollAmountCorrections||[])].forEach(c=>{
      if(c?.id)merged.set(String(c.id),c);
    });
    return [...merged.values()]
      .filter(c=>String(c.settlement_id)===String(s?.id)&&c.adjustment_type==='overtime_pay'&&(!staffId||String(c.staff_id)===String(staffId)))
      .reduce((sum,c)=>sum+(Number(c.calculated_amount)||0),0);
  }"""
if old not in summary:
    raise SystemExit('correctionAmount anchor not found')
summary = summary.replace(old, new, 1)

# 2. Rename the money column so settled snapshot display is not described as a live system calculation.
old = "th.textContent='系統計算加班費'"
new = "th.textContent='月結加班費'"
if old not in summary:
    raise SystemExit('summary money header anchor not found')
summary = summary.replace(old, new, 1)

# 3. Old V1 snapshot: show correction amount but never fabricate an original/final total.
old = """        }else{
          td.dataset.snapshotLocked='1';
          const nextHtml='<span class=\"pr-money missing\">舊月結</span><div class=\"ot-detail\">此月份建立於金額快照功能前，僅保留當時的時數快照，不以目前薪資重新計算。</div>';
          if(td.innerHTML!==nextHtml)td.innerHTML=nextHtml;
        }"""
new = """        }else{
          const corr=correctionAmount(s,staffId);
          td.dataset.snapshotLocked='1';
          const nextHtml=corr
            ? `<span class=\"pr-money missing\">原金額未留存</span><div class=\"ot-detail\">月結後更正 ${corr>0?'+':''}${money(corr).replace('NT$ ','')}・完整總額無法由舊快照還原</div>`
            : '<span class=\"pr-money missing\">原金額未留存</span><div class=\"ot-detail\">此月份建立於金額快照功能前，只保留當時時數；不以目前薪資回推歷史金額。</div>';
          if(td.innerHTML!==nextHtml)td.innerHTML=nextHtml;
        }"""
if old not in summary:
    raise SystemExit('old snapshot row anchor not found')
summary = summary.replace(old, new, 1)

# 4. Old V1 snapshot total notice: same single-source rule.
old = """    }else{
      const nextHtml='<h3>🔒 舊版月結快照</h3><p>此月份是在「金額快照」功能上線前完成月結，因此保留原有時數快照，但不會用現在的薪資基數回頭重算金額。若需調整，請使用月結後更正單。</p>';
      if(note.innerHTML!==nextHtml)note.innerHTML=nextHtml;
    }"""
new = """    }else{
      const corr=correctionAmount(s);
      const nextHtml=`<h3>🔒 舊版月結快照</h3><p>此月份是在「金額快照」功能上線前完成月結，因此原始加班費金額未保存。系統只保留當時時數，不會用目前薪資基數回頭重算。</p><div class=\"ot-rule-highlight\">原月結加班費：<strong>未留存</strong>${corr?`　｜　月結後更正：<strong>${corr>0?'+':''}${money(corr).replace('NT$ ','')}</strong>`:''}　｜　完整目前認列總額：<strong>無法由舊快照還原</strong></div>`;
      if(note.innerHTML!==nextHtml)note.innerHTML=nextHtml;
    }"""
if old not in summary:
    raise SystemExit('old snapshot notice anchor not found')
summary = summary.replace(old, new, 1)

# 5. Old V1 detail modal: display correction separately and keep original total explicitly unknown.
old = """      ${version>=2?`<div class=\"ot-rule-highlight\" style=\"margin-top:0\">原月結加班費：<strong>${money(original)}</strong>${expiredAmount?`｜其中到期換休折算：<strong>${money(expiredAmount)}</strong>（${dur(expiredMinutes)}）`:''}${corr?`｜月結後更正：<strong>${corr>0?'+':''}${money(corr).replace('NT$ ','')}</strong>`:''}｜目前認列：<strong>${money(original+corr)}</strong></div>`:'<div class=\"ot-rule-highlight\" style=\"margin-top:0\">此為舊版月結，只保存原始時數，不使用目前薪資回推歷史金額。</div>'}"""
new = """      ${version>=2?`<div class=\"ot-rule-highlight\" style=\"margin-top:0\">原月結加班費：<strong>${money(original)}</strong>${expiredAmount?`｜其中到期換休折算：<strong>${money(expiredAmount)}</strong>（${dur(expiredMinutes)}）`:''}${corr?`｜月結後更正：<strong>${corr>0?'+':''}${money(corr).replace('NT$ ','')}</strong>`:''}｜目前認列：<strong>${money(original+corr)}</strong></div>`:`<div class=\"ot-rule-highlight\" style=\"margin-top:0\">原月結加班費：<strong>未留存</strong>${corr?`｜月結後更正：<strong>${corr>0?'+':''}${money(corr).replace('NT$ ','')}</strong>`:''}｜完整目前認列總額：<strong>無法由舊快照還原</strong></div>`}"""
if old not in summary:
    raise SystemExit('old snapshot detail anchor not found')
summary = summary.replace(old, new, 1)

# 6. Once a month has a settlement, disable live monetary rendering entirely.
old = """  function prEnhancePayroll(){
    if(state.page!=='overtime'||state.overtimeView!=='payroll'||!prCanReview()||!state.payrollRatesLoaded)return;"""
new = """  function prEnhancePayroll(){
    if(state.page!=='overtime'||state.overtimeView!=='payroll'||!prCanReview()||!state.payrollRatesLoaded)return;
    // 已月結月份一律由月結快照＋更正紀錄顯示，禁止再用目前資料即時重算。
    if(prSettlement())return;"""
if old not in calc:
    raise SystemExit('prEnhancePayroll anchor not found')
calc = calc.replace(old, new, 1)

old = """  function prAppendPayrollDetail(staffId){
    if(!prCanReview())return;"""
new = """  function prAppendPayrollDetail(staffId){
    if(!prCanReview()||prSettlement())return;"""
if old not in calc:
    raise SystemExit('prAppendPayrollDetail anchor not found')
calc = calc.replace(old, new, 1)

summary_path.write_text(summary, encoding='utf-8')
calc_path.write_text(calc, encoding='utf-8')
