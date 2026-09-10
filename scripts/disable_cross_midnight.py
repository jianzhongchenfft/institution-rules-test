from pathlib import Path

# 1) Core overtime form: allow 00:00 as same-day 24:00, but reject true cross-midnight ranges.
p = Path('v52/overtime-patch.txt')
s = p.read_text(encoding='utf-8')
old = """  function overtimeMinutesBetween(start,end){
    const s=overtimeNormalizeTime(start),e=overtimeNormalizeTime(end);
    if(!overtimeValid24h(s) || !overtimeValid24h(e)) return 0;
    const toMin = value => {
      const [h,m] = String(value).split(':').map(Number);
      return h*60 + m;
    };
    return Math.max(0, toMin(e)-toMin(s));
  }
"""
new = """  function overtimeMinutesBetween(start,end){
    const s=overtimeNormalizeTime(start),e=overtimeNormalizeTime(end);
    if(!overtimeValid24h(s) || !overtimeValid24h(e)) return 0;
    const toMin = value => {
      const [h,m] = String(value).split(':').map(Number);
      return h*60 + m;
    };
    const startMin=toMin(s),endMin=toMin(e);
    if(endMin===0 && startMin>0) return 1440-startMin;
    return endMin>startMin ? endMin-startMin : 0;
  }

  function overtimeCrossesMidnight(start,end){
    const s=overtimeNormalizeTime(start),e=overtimeNormalizeTime(end);
    if(!overtimeValid24h(s) || !overtimeValid24h(e)) return false;
    const [sh,sm]=s.split(':').map(Number),[eh,em]=e.split(':').map(Number);
    const startMin=sh*60+sm,endMin=eh*60+em;
    return endMin<startMin && endMin!==0;
  }
"""
if old not in s:
    raise SystemExit('overtimeMinutesBetween anchor not found')
s = s.replace(old, new, 1)

old = """      if($('otMinuteCalc')) $('otMinuteCalc').textContent=!valid?'請選擇完整的開始與結束時間':minutes?`${minutes}分鐘（${overtimeDurationLabel(minutes)}）`:'結束時間須晚於開始時間';
"""
new = """      if($('otMinuteCalc')) $('otMinuteCalc').textContent=!valid
        ? '請選擇完整的開始與結束時間'
        : overtimeCrossesMidnight(start,end)
          ? '跨午夜加班不可用一筆申請；請分成兩筆。第一天結束時間填 00:00（視同 24:00），第二天改以隔日 00:00 起另行申請。'
          : minutes
            ? `${minutes}分鐘（${overtimeDurationLabel(minutes)}）`
            : '結束時間須晚於開始時間';
"""
if old not in s:
    raise SystemExit('updateOvertimeCalc anchor not found')
s = s.replace(old, new, 1)

anchor = """    if(timeBased && (!['00','10','20','30','40','50'].includes(String(start).slice(3,5)) || !['00','10','20','30','40','50'].includes(String(end).slice(3,5)))){toast('加班時間請以10分鐘為間隔','warn');return false;}
    if(timeBased && overtimeMinutes<=0){toast('結束時間須晚於開始時間','warn');return false;}
"""
replacement = """    if(timeBased && (!['00','10','20','30','40','50'].includes(String(start).slice(3,5)) || !['00','10','20','30','40','50'].includes(String(end).slice(3,5)))){toast('加班時間請以10分鐘為間隔','warn');return false;}
    if(timeBased && overtimeCrossesMidnight(start,end)){toast('跨午夜加班請分成兩筆申請：第一天申請至 00:00（視同 24:00），第二天改以隔日 00:00 起另行申請。','warn');return false;}
    if(timeBased && overtimeMinutes<=0){toast('結束時間須晚於開始時間','warn');return false;}
"""
if anchor not in s:
    raise SystemExit('saveOvertime validation anchor not found')
s = s.replace(anchor, replacement, 1)

rules_anchor = """          <li>申請時應填寫日期、開始時間、結束時間及加班事由；開始與結束時間採24小時制，並以10分鐘為間隔（分鐘僅00、10、20、30、40、50），系統依時間自動計算加班分鐘數。</li>
"""
rules_new = rules_anchor + """          <li>加班不得以單一申請跨越午夜；如實際工作跨日，請自行分成兩筆申請。第一天結束時間填00:00（視同當日24:00），第二天以隔日00:00為開始時間另行申請。</li>
"""
if rules_anchor not in s:
    raise SystemExit('rules anchor not found')
s = s.replace(rules_anchor, rules_new, 1)

s = s.replace(',split_group_id,split_part,split_day_type_confirmed', '', 1)
p.write_text(s, encoding='utf-8')

# 2) Payroll calculation patch: same time interpretation and clear warning for true cross-midnight input.
p = Path('v52/overtime-payroll-calc-patch.txt')
s = p.read_text(encoding='utf-8')
old = """  function prMinutes(a,b){
    a=prNormTime(a);b=prNormTime(b);if(!a||!b)return 0;
    const [ah,am]=a.split(':').map(Number),[bh,bm]=b.split(':').map(Number);
    return Math.max(0,(bh*60+bm)-(ah*60+am));
  }
"""
new = """  function prMinutes(a,b){
    a=prNormTime(a);b=prNormTime(b);if(!a||!b)return 0;
    const [ah,am]=a.split(':').map(Number),[bh,bm]=b.split(':').map(Number);
    const start=ah*60+am,end=bh*60+bm;
    if(end===0&&start>0)return 1440-start;
    return end>start?end-start:0;
  }
  function prCrossesMidnight(a,b){
    a=prNormTime(a);b=prNormTime(b);if(!a||!b)return false;
    const [ah,am]=a.split(':').map(Number),[bh,bm]=b.split(':').map(Number);
    const start=ah*60+am,end=bh*60+bm;
    return end<start&&end!==0;
  }
"""
if old not in s:
    raise SystemExit('prMinutes anchor not found')
s = s.replace(old, new, 1)

anchor = """    const start=prSelected('otStart'),end=prSelected('otEnd');
    const minutes=prMinutes(start,end);
    const rate=prRateFor(state.profile?.id,date);
"""
replacement = """    const start=prSelected('otStart'),end=prSelected('otEnd');
    if(prCrossesMidnight(start,end)){box.textContent='跨午夜加班請分成兩筆申請：第一天申請至 00:00（視同 24:00），第二天改以隔日 00:00 起另行申請。';return;}
    const minutes=prMinutes(start,end);
    const rate=prRateFor(state.profile?.id,date);
"""
if anchor not in s:
    raise SystemExit('prUpdatePreview anchor not found')
s = s.replace(anchor, replacement, 1)

anchor = """    const existingId=state.workflowEditingOvertimeId||null;
    if(!date||!start||!end||minutes<=0||!reason||!comp){toast('請完整填寫日期、時間、處理方式與加班事由','warn');return false;}
"""
replacement = """    const existingId=state.workflowEditingOvertimeId||null;
    if(prCrossesMidnight(start,end)){toast('跨午夜加班請分成兩筆申請：第一天申請至 00:00（視同 24:00），第二天改以隔日 00:00 起另行申請。','warn');return false;}
    if(!date||!start||!end||minutes<=0||!reason||!comp){toast('請完整填寫日期、時間、處理方式與加班事由','warn');return false;}
"""
if anchor not in s:
    raise SystemExit('prSaveNewType anchor not found')
s = s.replace(anchor, replacement, 1)
p.write_text(s, encoding='utf-8')

# 3) Personal-hours preview: 00:00 means 24:00 and true cross-midnight shows the same instruction.
p = Path('v52/overtime-personal-hours-patch.txt')
s = p.read_text(encoding='utf-8')
old = """  function minutesBetween(a,b){if(!a||!b)return 0;const [ah,am]=a.split(':').map(Number),[bh,bm]=b.split(':').map(Number);return Math.max(0,bh*60+bm-ah*60-am);}
"""
new = """  function minutesBetween(a,b){if(!a||!b)return 0;const [ah,am]=a.split(':').map(Number),[bh,bm]=b.split(':').map(Number);const start=ah*60+am,end=bh*60+bm;if(end===0&&start>0)return 1440-start;return end>start?end-start:0;}
  function crossesMidnight(a,b){if(!a||!b)return false;const [ah,am]=a.split(':').map(Number),[bh,bm]=b.split(':').map(Number);const start=ah*60+am,end=bh*60+bm;return end<start&&end!==0;}
"""
if old not in s:
    raise SystemExit('personal hours minutesBetween anchor not found')
s = s.replace(old, new, 1)
anchor = """    const start=selectedTime('otStart'),end=selectedTime('otEnd');
    const rate=rateFor(state.profile?.id,date),minutes=minutesBetween(start,end);
"""
replacement = """    const start=selectedTime('otStart'),end=selectedTime('otEnd');
    if(crossesMidnight(start,end)){box.textContent='跨午夜加班請分成兩筆申請：第一天申請至 00:00（視同 24:00），第二天改以隔日 00:00 起另行申請。';return;}
    const rate=rateFor(state.profile?.id,date),minutes=minutesBetween(start,end);
"""
if anchor not in s:
    raise SystemExit('personal hours preview anchor not found')
s = s.replace(anchor, replacement, 1)
p.write_text(s, encoding='utf-8')

# 4) Overlap guard: a same-day row ending 00:00 represents 24:00 and must participate in overlap checks.
p = Path('v52/overtime-workflow-patch.txt')
s = p.read_text(encoding='utf-8')
old = """  const overlap=(a,b,c,d)=>{
    const x=[min(a),min(b),min(c),min(d)];
    return x.every(Number.isFinite)&&x[0]<x[3]&&x[1]>x[2];
  };
"""
new = """  const interval=(a,b)=>{
    const start=min(a),rawEnd=min(b);
    if(!Number.isFinite(start)||!Number.isFinite(rawEnd))return null;
    const end=rawEnd===0&&start>0?1440:rawEnd;
    return end>start?[start,end]:null;
  };
  const overlap=(a,b,c,d)=>{
    const x=interval(a,b),y=interval(c,d);
    return !!x&&!!y&&x[0]<y[1]&&x[1]>y[0];
  };
"""
if old not in s:
    raise SystemExit('workflow overlap anchor not found')
s = s.replace(old, new, 1)
p.write_text(s, encoding='utf-8')

# 5) Loader: stop loading automatic midnight split patch.
p = Path('v51/part07.txt')
s = p.read_text(encoding='utf-8')
block = """      const midnightSplitRes = await fetch('v52/overtime-midnight-split-patch.txt',{cache:'no-store'});
      if(!midnightSplitRes.ok) throw new Error(`v52/overtime-midnight-split-patch.txt 載入失敗（${midnightSplitRes.status}）`);
      eval(await midnightSplitRes.text());

"""
if block not in s:
    raise SystemExit('midnight split loader block not found')
s = s.replace(block, '', 1)
p.write_text(s, encoding='utf-8')

# 6) Withdraw patch: remove split-group withdrawal branch; all future requests are independent rows.
p = Path('v52/overtime-withdraw-patch.txt')
s = p.read_text(encoding='utf-8')
s = s.replace("""    const grouped=kind==='overtime'&&!!row.split_group_id;

    openModal({
      title:grouped?'撤回跨午夜申請':'撤回申請',
      html:`
        <div style=\"font-size:14px;font-weight:800;color:#344054\">${grouped?'確定撤回這組跨午夜申請？':'確定撤回此筆申請？'}</div>
        <div class=\"ot-detail\" style=\"margin-top:10px\">日期：${escapeHTML(date||'—')}　｜　時間：${escapeHTML(time)}</div>
        ${grouped?'<div class=\"ot-rule-highlight\">此申請是跨午夜自動拆成的兩筆紀錄，撤回時會將同一組兩筆一起刪除。</div>':''}`,
""","""    openModal({
      title:'撤回申請',
      html:`
        <div style=\"font-size:14px;font-weight:800;color:#344054\">確定撤回此筆申請？</div>
        <div class=\"ot-detail\" style=\"margin-top:10px\">日期：${escapeHTML(date||'—')}　｜　時間：${escapeHTML(time)}</div>`,
""",1)
old = """      if(kind==='overtime'&&row.split_group_id){
        const {data,error}=await db.rpc('delete_split_overtime_group',{p_group_id:row.split_group_id});
        if(error)throw error;
        if(Number(data)!==2)throw new Error('跨午夜申請未能完整撤回，請重新整理後再操作');
      }else{
        const table=kind==='leave'?'comp_leave_usages':'overtime_requests';
        const {data,error}=await db.from(table)
          .delete()
          .eq('id',id)
          .eq('applicant_staff_id',state.profile.id)
          .eq('status','pending')
          .select('id')
          .maybeSingle();
        if(error)throw error;
        if(!data)throw new Error('申請狀態已變更，請重新整理後再操作');
      }
"""
new = """      const table=kind==='leave'?'comp_leave_usages':'overtime_requests';
      const {data,error}=await db.from(table)
        .delete()
        .eq('id',id)
        .eq('applicant_staff_id',state.profile.id)
        .eq('status','pending')
        .select('id')
        .maybeSingle();
      if(error)throw error;
      if(!data)throw new Error('申請狀態已變更，請重新整理後再操作');
"""
if old not in s:
    raise SystemExit('withdraw split branch anchor not found')
s = s.replace(old, new, 1)
s = s.replace("      toast(kind==='overtime'&&row.split_group_id?'跨午夜兩筆申請已一起撤回':'申請已撤回','success');","      toast('申請已撤回','success');",1)
if 'delete_split_overtime_group' in s or 'split_group_id' in s:
    raise SystemExit('split withdrawal logic still present')
p.write_text(s, encoding='utf-8')

print('cross-midnight automatic split disabled; manual two-row application enabled')
