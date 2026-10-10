/* 劉信子內部管理系統：共用民國日期工具 V1.2（獨立測試，尚未接入既有表單） */
(function(root){
 'use strict';
 if(root.rocDateKit)return;
 var pad=n=>String(n).padStart(2,'0');
 var text=x=>String(x==null?'':x).trim().replace(/[０-９]/g,c=>String(c.charCodeAt(0)-65296));
 function leap(y){return y%4===0&&(y%100!==0||y%400===0);}
 function valid(y,m,d){return Number.isInteger(y)&&y>=1&&y<=9999&&Number.isInteger(m)&&m>=1&&m<=12&&Number.isInteger(d)&&d>=1&&d<=[31,leap(y)?29:28,31,30,31,30,31,31,30,31,30,31][m-1];}
 function makeISO(y,m,d){return String(y).padStart(4,'0')+'-'+pad(m)+(d==null?'':'-'+pad(d));}
 function isoDate(s){var a=/^(\d{4})-(\d{2})-(\d{2})$/.exec(text(s));return a&&valid(+a[1],+a[2],+a[3])?{y:+a[1],m:+a[2],d:+a[3]}:null;}
 function isoMonth(s){var a=/^(\d{4})-(\d{2})$/.exec(text(s));return a&&+a[1]>=1&&+a[1]<=9999&&+a[2]>=1&&+a[2]<=12?{y:+a[1],m:+a[2]}:null;}
 function yText(y){return y>=1912?String(y-1911):'民前'+String(1912-y);}
 function fromRocYear(s){if(/^民前[1-9]\d{0,3}$/.test(s))return 1912-Number(s.slice(2));return /^(?:[1-9]\d{0,2}|0[0-9]{2})$/.test(s)&&Number(s)>0?Number(s)+1911:null;}
 function parse(s,month){
   var raw=text(s).replace(/\s/g,'').replace(/[.\-．]/g,'/').replace(/年/g,'/').replace(/月/g,month?'':'/').replace(/日$/,'').replace(/\/$/,'');
   // 無分隔符號時，最末2碼為月份；日期則再往前取2碼為日。
   // 民國年可以是2碼(84)或3碼(084、115)，避免猜測不完整月份/日期。
   var compact=month?/^(\d{2,3})(\d{2})$/.exec(raw):
     /^(\d{2,3})(\d{2})(\d{2})$/.exec(raw);
   var a=compact||(month?/^(民前\d{1,4}|\d{1,3})\/(\d{1,2})$/:/^(民前\d{1,4}|\d{1,3})\/(\d{1,2})\/(\d{1,2})$/).exec(raw);
   if(!a)return null;
   var y=fromRocYear(a[1]),m=Number(a[2]),d=month?1:Number(a[3]);
   return y!==null&&valid(y,m,d)?makeISO(y,m,month?null:d):null;
 }
 function formatDate(v){var p=isoDate(v);return p?yText(p.y)+'/'+pad(p.m)+'/'+pad(p.d):'—';}
 function formatMonth(v){var p=isoMonth(v)||isoDate(v);return p?yText(p.y)+'年'+p.m+'月':'—';}
 function formatPrintDate(v){var p=isoDate(v);return p?yText(p.y)+'年'+p.m+'月'+p.d+'日':'—';}
 function formatDateTime(v){
   var a=/^(\d{4}-\d{2}-\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:\d{2})?$/.exec(text(v));
   if(!a||!isoDate(a[1])||+a[2]>23||+a[3]>59||Number(a[4]||0)>59)return '—';
   if(a[5]){
     var dt=new Date(String(v).replace(' ','T'));if(Number.isNaN(dt.getTime()))return '—';
     var parts={};new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Taipei',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(dt).forEach(x=>{parts[x.type]=x.value;});
     return formatDate(parts.year+'-'+parts.month+'-'+parts.day)+' '+parts.hour+':'+parts.minute;
   }
   return formatDate(a[1])+' '+a[2]+':'+a[3];
 }
 function today(){var d=new Date();return makeISO(d.getFullYear(),d.getMonth()+1,d.getDate());}
 function css(){
   if(document.getElementById('roc-date-kit-style'))return;
   var rules=[
    '.rdk{position:relative;display:inline-flex;align-items:flex-start;flex-wrap:wrap;gap:4px;max-width:100%;font-family:inherit}',
    '.rdk-text{box-sizing:border-box;width:152px;max-width:100%;height:36px;border:1px solid #d0d5dd;border-radius:8px;background:white;padding:7px 8px;font:inherit;font-size:13px;color:#344054}',
    '.rdk.month .rdk-text{width:145px}',
    '.rdk-text[aria-invalid="true"]{border-color:#d92d20;outline-color:#d92d20}',
    '.rdk-toggle,.rdk-nav,.rdk-small{border:1px solid #d0d5dd;border-radius:7px;background:white;color:#475467;cursor:pointer}',
    '.rdk-toggle{height:36px;min-width:36px;font-size:17px}.rdk-toggle:disabled{opacity:.5;cursor:default}',
    '.rdk-error{flex-basis:100%;color:#b42318;font-size:11px}',
    '.rdk-popup{box-sizing:border-box;position:absolute;z-index:1200;left:0;top:calc(100% + 5px);width:284px;max-width:calc(100vw - 20px);padding:12px;border:1px solid #ebd0c6;border-radius:12px;background:white;color:#344054;box-shadow:0 10px 24px rgba(0,0,0,.16)}',
    '.rdk-popup[hidden]{display:none!important}',
    '.rdk-head{display:flex;gap:5px;align-items:center;justify-content:space-between;margin-bottom:8px}',
    '.rdk-head label{display:flex;gap:3px;align-items:center;font-size:12px}',
    '.rdk-year{box-sizing:border-box;width:67px;padding:4px;border:1px solid #d0d5dd;border-radius:6px;font-size:12px}',
    '.rdk-month-select{width:58px;padding:4px 2px;border:1px solid #d0d5dd;border-radius:6px;font-size:12px}',
    '.rdk-nav{height:28px;min-width:27px;font-size:18px}',
    '.rdk-week,.rdk-days{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:3px;text-align:center}',
    '.rdk-week{font-size:11px;color:#667085;margin-bottom:5px}',
    '.rdk-day{height:30px;padding:0;border:1px solid transparent;border-radius:6px;background:white;color:#344054;cursor:pointer;font:inherit;font-size:12px}',
    '.rdk-months{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:7px}',
    '.rdk-month-choice{height:38px;border:1px solid #e5e7eb;border-radius:7px;background:white;color:#344054;cursor:pointer}',
    '.rdk-day.selected,.rdk-month-choice.selected{background:#dc9479;color:white;border-color:#dc9479}',
    '.rdk-day:disabled,.rdk-month-choice:disabled{opacity:.25;cursor:default}',
    '.rdk-nav:hover,.rdk-day:hover:not(:disabled),.rdk-month-choice:hover:not(:disabled){background:#fff3ed;border-color:#dc9479}',
    '.rdk-foot{display:flex;justify-content:space-between;gap:6px;margin-top:9px}',
    '.rdk-small{padding:5px 8px;font-size:12px}',
    '.rdk-text:focus-visible,.rdk-popup button:focus-visible{outline:2px solid #dc9479;outline-offset:1px}'
   ];
   var style=document.createElement('style');style.id='roc-date-kit-style';style.textContent=rules.join('\n');document.head.append(style);
 }
 function node(tag,cls,value){var x=document.createElement(tag);if(cls)x.className=cls;if(value!==undefined)x.textContent=value;return x;}
 function btn(label,cls,fn){var x=node('button',cls,label);x.type='button';x.addEventListener('click',fn);return x;}
 function mount(target,options,month){
   if(typeof document==='undefined')throw Error('日期元件需要瀏覽器環境');
   var host=typeof target==='string'?document.querySelector(target):target;
   if(!host)throw Error('找不到日期元件容器');
   var opt=options||{},part=month?isoMonth:isoDate,parser=month?x=>parse(x,true):x=>parse(x,false),fmt=month?formatMonth:formatDate;
   var current=opt.value||'',min=opt.min||'',max=opt.max||'';
   if(current&&!part(current))throw Error('初始值需為有效西元 ISO 日期');
   if((min&&!part(min))||(max&&!part(max)))throw Error('日期範圍需為有效西元 ISO 日期');
   if(min&&max&&min>max)throw Error('日期範圍起日不得晚於迄日');
   css();
   var wrap=node('div','rdk'+(month?' month':''));
   var input=node('input','rdk-text');input.type='text';input.inputMode='numeric';input.autocomplete='off';input.placeholder=month?'11510 或 115年10月':'1151010 或 840306';
   if(opt.id)input.id=opt.id;
   if(opt.disabled)input.disabled=true;
   if(opt.required)input.required=true;
   var hidden=node('input');hidden.type='hidden';if(opt.name)hidden.name=opt.name;
   var toggle=btn('▦','rdk-toggle',flip);toggle.setAttribute('aria-label',month?'選擇民國月份':'選擇民國日期');if(opt.disabled)toggle.disabled=true;
   var pop=node('div','rdk-popup');pop.hidden=true;pop.setAttribute('role','dialog');pop.setAttribute('aria-label',month?'民國月份選擇器':'民國日期選擇器');
   var error=node('div','rdk-error');error.setAttribute('role','alert');
   wrap.append(input,toggle,hidden,error,pop);host.replaceChildren(wrap);
   var base=part(current)||isoDate(today()),yr=base.y,mo=base.m;
   function allowed(s){return (!min||s>=min)&&(!max||s<=max);}
   function err(message){error.textContent=message||'';if(message)input.setAttribute('aria-invalid','true');else input.removeAttribute('aria-invalid');}
   function setISO(value,notify){
     var v=value||'';if(v&&(!part(v)||!allowed(v)))return false;
     var changed=current!==v;current=v;input.value=v?fmt(v):'';hidden.value=v;err('');
     if(v){var d=part(v);yr=d.y;mo=d.m;}
     if(notify&&changed&&typeof opt.onChange==='function')opt.onChange(v);
     return true;
   }
   function commit(){
     var raw=input.value.trim();
     if(!raw){if(opt.required){hidden.value='';err('請填寫'+(month?'月份':'日期'));return false;}return setISO('',true);}
     var iso=parser(raw);
     if(!iso){hidden.value='';err('日期格式或內容不正確，請輸入'+(month?'115年10月':'115/10/10'));return false;}
     if(!allowed(iso)){hidden.value='';err('日期不在允許範圍內');return false;}
     return setISO(iso,true);
   }
   function close(){pop.hidden=true;document.removeEventListener('pointerdown',outside);}
   function outside(e){if(!wrap.contains(e.target))close();}
   function choice(value){if(setISO(value,true)){close();input.focus();}}
   function move(delta){
     var y=yr,m=mo+delta;
     while(m<1){m+=12;y--;}
     while(m>12){m-=12;y++;}
     if(y-1911<1||y-1911>999)return;
     yr=y;mo=m;draw();
   }
   function draw(){
     pop.replaceChildren();
     var head=node('div','rdk-head');
     var prev=btn('‹','rdk-nav',()=>move(month?-12:-1));prev.setAttribute('aria-label',month?'上一年':'上個月');
     var next=btn('›','rdk-nav',()=>move(month?12:1));next.setAttribute('aria-label',month?'下一年':'下個月');
     var label=node('label',null,'民國');
     var year=node('input','rdk-year');year.type='number';year.min='1';year.max='999';year.value=String(yr-1911);year.setAttribute('aria-label','民國年');
     year.addEventListener('change',()=>{var value=+year.value;if(Number.isInteger(value)&&value>=1&&value<=999){yr=value+1911;draw();}else year.value=String(yr-1911);});
     label.append(year,document.createTextNode('年'));head.append(prev,label);
     if(!month){
       var selector=node('select','rdk-month-select');selector.setAttribute('aria-label','月份');
       for(var m=1;m<=12;m++){var op=node('option',null,m+'月');op.value=String(m);op.selected=m===mo;selector.append(op);}
       selector.addEventListener('change',()=>{mo=+selector.value;draw();});head.append(selector);
     }
     head.append(next);pop.append(head);
     if(month){
       var months=node('div','rdk-months');
       for(var mm=1;mm<=12;mm++){let val=makeISO(yr,mm);var b=btn(mm+'月','rdk-month-choice',()=>choice(val));if(val===current)b.classList.add('selected');if(!allowed(val))b.disabled=true;months.append(b);}
       pop.append(months);
     }else{
       var week=node('div','rdk-week');['日','一','二','三','四','五','六'].forEach(w=>week.append(node('span',null,w)));pop.append(week);
       var grid=node('div','rdk-days'),weekday=new Date(yr,mo-1,1).getDay(),count=[31,leap(yr)?29:28,31,30,31,30,31,31,30,31,30,31][mo-1];
       for(var w=0;w<weekday;w++)grid.append(node('span'));
       for(var day=1;day<=count;day++){let val=makeISO(yr,mo,day);var b=btn(String(day),'rdk-day',()=>choice(val));if(val===current)b.classList.add('selected');if(!allowed(val))b.disabled=true;grid.append(b);}
       pop.append(grid);
     }
     var foot=node('div','rdk-foot');
     foot.append(btn(month?'本月':'今天','rdk-small',()=>{var t=month?today().slice(0,7):today();if(allowed(t))choice(t);}));
     if(!opt.required)foot.append(btn('清除','rdk-small',()=>choice('')));
     pop.append(foot);
   }
   function flip(){
     if(opt.disabled)return;
     if(!pop.hidden){close();return;}
     var d=part(current)||isoDate(today());yr=d.y;mo=d.m;draw();pop.hidden=false;document.addEventListener('pointerdown',outside);
     if(pop.getBoundingClientRect().right>window.innerWidth-8){pop.style.left='auto';pop.style.right='0';}else{pop.style.left='0';pop.style.right='auto';}
   }
   input.addEventListener('input',()=>{var v=parser(input.value);hidden.value=v&&allowed(v)?v:'';err('');});
   input.addEventListener('change',commit);
   input.addEventListener('blur',()=>{if(input.value!==(current?fmt(current):''))commit();});
   wrap.addEventListener('keydown',e=>{if(e.key==='Escape'&&!pop.hidden){e.preventDefault();close();input.focus();}});
   setISO(current,false);
   return Object.freeze({input:input,element:wrap,getISO:()=>commit()?current:null,validate:commit,setISO:v=>setISO(v,false),open:flip,destroy:()=>{close();host.replaceChildren();}});
 }
 root.rocDateKit=Object.freeze({
   parseDate:s=>parse(s,false),parseMonth:s=>parse(s,true),
   formatDate:formatDate,formatMonth:formatMonth,formatPrintDate:formatPrintDate,formatDateTime:formatDateTime,
   mountDate:(el,opt)=>mount(el,opt,false),mountMonth:(el,opt)=>mount(el,opt,true),todayISO:today
 });
})(typeof window!=='undefined'?window:globalThis);
