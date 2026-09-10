from pathlib import Path
import re

p=Path('v52/overtime-payroll-calc-patch.txt')
s=p.read_text(encoding='utf-8')
s=s.replace("const newTimedTypes=new Set(['rest_day_overtime','national_holiday_overtime','regular_day_off_overtime']);","const newTimedTypes=new Set(['rest_day_overtime','national_holiday_overtime']);")
s=s.replace("regular_day_off_overtime:'例假日出勤',","regular_day_off_overtime:'例假日延續（前一日跨午夜）',")
s=s.replace('      <option value="regular_day_off_overtime">例假日出勤（僅法定例外）</option>\n','')
s=s.replace("    const comp=type==='regular_day_off_overtime'?'overtime_pay':document.getElementById('otCompensation')?.value;","    const comp=document.getElementById('otCompensation')?.value;")
s=re.sub(r"\n    if\(type==='regular_day_off_overtime'\)\{\n      if\(minutes>720\).*?\n    \}","",s,count=1,flags=re.S)
s=s.replace("      emergency_basis_confirmed:type==='regular_day_off_overtime',\n","")
s=s.replace("regular_day_off_overtime:'例假日出勤',holiday_overtime:'假日加班（舊分類）'","regular_day_off_overtime:'例假日延續（前一日跨午夜）',holiday_overtime:'假日加班（舊分類）'")
s=s.replace('<option value="regular_day_off_overtime">例假日出勤</option>','')
start=s.find('  function prFormWarning(){')
end=s.find('  function prEnhanceTypeSelect(){',start)
if start<0 or end<0: raise SystemExit('prFormWarning anchors not found')
new_func="""  function prFormWarning(){
    const type=document.getElementById('otType')?.value;
    const comp=document.getElementById('otCompensation');
    const help=document.getElementById('otCompensationHelp');
    const modal=document.getElementById('otType')?.closest('.modal');
    if(!modal)return;
    let warn=modal.querySelector('#prLegalWarn');
    if(!warn){warn=document.createElement('div');warn.id='prLegalWarn';warn.className='pr-legal-warn hidden';document.getElementById('otCompensation')?.closest('.field')?.insertAdjacentElement('afterend',warn);}
    if(type!=='holiday_visit_comp'&&comp)comp.disabled=false;
    warn.classList.add('hidden');warn.innerHTML='';
    if(type==='national_holiday_overtime'&&help)help.textContent='國定假日出勤8小時內，若選擇領加班費，月薪制原工資外應再加發一日工資。';
    else if(type==='rest_day_overtime'&&help)help.textContent='休息日加班依休息日法定倍率計算；亦可依規定選擇換休。';
    else if(type==='overtime'&&help)help.textContent='平日加班可選擇領加班費或換休。';
  }

"""
s=s[:start]+new_func+s[end:]
for token in ['例假日出勤（僅法定例外）','prEmergencyConfirm',"emergency_basis_confirmed:type==='regular_day_off_overtime'"]:
    if token in s: raise SystemExit('legacy regular-day direct flow remains: '+token)
p.write_text(s,encoding='utf-8')

p=Path('v52/overtime-midnight-split-patch.txt')
s=p.read_text(encoding='utf-8')
old="const timedTypes=new Set(['overtime','rest_day_overtime','national_holiday_overtime']);"
new="const directTypes=new Set(['overtime','rest_day_overtime','national_holiday_overtime']);\n  const timedTypes=new Set([...directTypes,'regular_day_off_overtime']);"
if old not in s: raise SystemExit('midnight timedTypes anchor not found')
s=s.replace(old,new,1)
s=s.replace("    national_holiday_overtime:'國定假日出勤'\n","    national_holiday_overtime:'國定假日出勤',\n    regular_day_off_overtime:'例假日延續（前一日跨午夜）'\n",1)
s=s.replace('!timedTypes.has(type)','!directTypes.has(type)',1)
s=s.replace('!timedTypes.has(v.type)','!directTypes.has(v.type)',1)
marker="    if(!timedTypes.has(type)||!norm(start)||!norm(end)||!crosses(start,end))return;"
if marker not in s: raise SystemExit('midnight click capture anchor not found')
s=s.replace(marker,"    if(!directTypes.has(type)||!norm(start)||!norm(end)||!crosses(start,end))return;",1)
old_options='''            <option value="overtime">平日加班</option>\n            <option value="rest_day_overtime">休息日加班</option>\n            <option value="national_holiday_overtime">國定假日出勤</option>'''
new_options=old_options+'\n            <option value="regular_day_off_overtime">例假日（僅前一日跨午夜延續）</option>'
if old_options not in s: raise SystemExit('midnight approval options anchor not found')
s=s.replace(old_options,new_options,1)
s=s.replace('          <div class="help">若翌日為例假日，請先退回本組申請，暫不直接核准。</div>','          <div class="help">例假日不可直接提出加班申請；此選項僅供前一日實際加班跨午夜後的翌日延續時段使用。</div>',1)
if '例假日（僅前一日跨午夜延續）' not in s: raise SystemExit('regular-day continuation choice missing')
p.write_text(s,encoding='utf-8')
