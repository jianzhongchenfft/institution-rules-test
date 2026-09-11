from pathlib import Path

p = Path('v52/overtime-payroll-summary-patch.txt')
s = p.read_text(encoding='utf-8')

repls = [
("""          td.innerHTML=`<span class=\"pr-money\">${money(finalAmount)}</span><div class=\"ot-detail\">原月結快照 ${money(original)}${expired?`・含到期換休折算 ${money(expired)}`:''}${corr?`・更正 ${corr>0?'+':''}${money(corr).replace('NT$ ','')}`:''}</div>`;""",
 """          const nextHtml=`<span class=\"pr-money\">${money(finalAmount)}</span><div class=\"ot-detail\">原月結快照 ${money(original)}${expired?`・含到期換休折算 ${money(expired)}`:''}${corr?`・更正 ${corr>0?'+':''}${money(corr).replace('NT$ ','')}`:''}</div>`;
          if(td.innerHTML!==nextHtml)td.innerHTML=nextHtml;"""),
("""          td.innerHTML='<span class=\"pr-money missing\">舊月結</span><div class=\"ot-detail\">此月份建立於金額快照功能前，僅保留當時的時數快照，不以目前薪資重新計算。</div>';""",
 """          const nextHtml='<span class=\"pr-money missing\">舊月結</span><div class=\"ot-detail\">此月份建立於金額快照功能前，僅保留當時的時數快照，不以目前薪資重新計算。</div>';
          if(td.innerHTML!==nextHtml)td.innerHTML=nextHtml;"""),
("""      note.innerHTML=`<h3>🔒 月結金額快照</h3><p>本月份結算時的薪資基數、加班日別、計算公式與加班費金額均已鎖定保存。後續調薪或修改薪資基數不會改變本月原始結算。${version>=6?'換休到期未休部分會依原加班日期的薪資基數與原同日倍率順位自動折算。':''}</p><div class=\"ot-rule-highlight\">原月結加班費：<strong>${money(original)}</strong>${expired?`　｜　其中到期換休折算：<strong>${money(expired)}</strong>（${dur(expiredMinutes)}）`:''}${corr?`　｜　月結後更正：<strong>${corr>0?'+':''}${money(corr).replace('NT$ ','')}</strong>`:''}　｜　目前認列：<strong>${money(finalAmount)}</strong></div>`;""",
 """      const nextHtml=`<h3>🔒 月結金額快照</h3><p>本月份結算時的薪資基數、加班日別、計算公式與加班費金額均已鎖定保存。後續調薪或修改薪資基數不會改變本月原始結算。${version>=6?'換休到期未休部分會依原加班日期的薪資基數與原同日倍率順位自動折算。':''}</p><div class=\"ot-rule-highlight\">原月結加班費：<strong>${money(original)}</strong>${expired?`　｜　其中到期換休折算：<strong>${money(expired)}</strong>（${dur(expiredMinutes)}）`:''}${corr?`　｜　月結後更正：<strong>${corr>0?'+':''}${money(corr).replace('NT$ ','')}</strong>`:''}　｜　目前認列：<strong>${money(finalAmount)}</strong></div>`;
      if(note.innerHTML!==nextHtml)note.innerHTML=nextHtml;"""),
("""      note.innerHTML='<h3>🔒 舊版月結快照</h3><p>此月份是在「金額快照」功能上線前完成月結，因此保留原有時數快照，但不會用現在的薪資基數回頭重算金額。若需調整，請使用月結後更正單。</p>';""",
 """      const nextHtml='<h3>🔒 舊版月結快照</h3><p>此月份是在「金額快照」功能上線前完成月結，因此保留原有時數快照，但不會用現在的薪資基數回頭重算金額。若需調整，請使用月結後更正單。</p>';
      if(note.innerHTML!==nextHtml)note.innerHTML=nextHtml;"""),
("""  let q=false;const obs=new MutationObserver(ms=>{if(q||!ms.some(m=>m.addedNodes?.length))return;q=true;setTimeout(()=>{q=false;update();},30);});obs.observe(document.body,{childList:true,subtree:true});""",
 """  let q=false;
  const obs=new MutationObserver(ms=>{
    if(q)return;
    const relevant=ms.some(m=>Array.from(m.addedNodes||[]).some(n=>{
      if(n.nodeType!==1)return false;
      if(n.id==='payrollAmountSnapshotNotice'||n.closest?.('#payrollAmountSnapshotNotice'))return false;
      return n.id==='otMain'||n.id==='payrollCorrectionPanel'||n.matches?.('.ot-table,.ot-rule-card,.stat-card')||!!n.querySelector?.('#otMain,#payrollCorrectionPanel,[data-payroll-detail],.ot-table,.stat-card');
    }));
    if(!relevant)return;
    q=true;setTimeout(()=>{q=false;update();},30);
  });
  obs.observe(document.body,{childList:true,subtree:true});""")
]

for old, new in repls:
    if old not in s:
        raise SystemExit('anchor not found:\n' + old[:160])
    s = s.replace(old, new, 1)

p.write_text(s, encoding='utf-8')
