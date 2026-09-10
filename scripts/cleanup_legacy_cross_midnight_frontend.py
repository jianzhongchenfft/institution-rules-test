from pathlib import Path
import re

# Core overtime loader: dropped DB columns must no longer be selected.
p = Path('v52/overtime-patch.txt')
s = p.read_text(encoding='utf-8')
s = s.replace(',split_group_id,split_part,split_day_type_confirmed', '')
for token in ('split_group_id','split_part','split_day_type_confirmed','next_day_request_type'):
    if token in s:
        raise SystemExit(f'legacy split token remains in overtime-patch: {token}')
p.write_text(s, encoding='utf-8')

# Payroll calc: regular-day continuation was only for the abandoned split flow.
p = Path('v52/overtime-payroll-calc-patch.txt')
s = p.read_text(encoding='utf-8')
s = s.replace(",\'regular_day_off_overtime\'", '')
s = s.replace("'regular_day_off_overtime',", '')
s = s.replace("regular_day_off_overtime:'例假日延續（前一日跨午夜）',\n", '')
s = s.replace("regular_day_off_overtime:'例假日延續（前一日跨午夜）',", '')
s = s.replace(",regular_day_off_overtime:'例假日延續（前一日跨午夜）'", '')
s = s.replace("['national_holiday_overtime','regular_day_off_overtime']", "['national_holiday_overtime']")
s = re.sub(
    r"\n    }else if\(type==='regular_day_off_overtime'\)\{.*?\n    \}\n    return \{ok:true",
    "\n    }\n    return {ok:true",
    s,
    count=1,
    flags=re.S,
)
if 'regular_day_off_overtime' in s:
    raise SystemExit('regular_day_off_overtime remains in payroll calc')
p.write_text(s, encoding='utf-8')

# Personal-hours preview: remove abandoned regular-day special case.
p = Path('v52/overtime-personal-hours-patch.txt')
s = p.read_text(encoding='utf-8')
s = s.replace("||type==='regular_day_off_overtime'", '')
if 'regular_day_off_overtime' in s:
    raise SystemExit('regular_day_off_overtime remains in personal-hours patch')
p.write_text(s, encoding='utf-8')

# Workflow overlap guard: regular-day split continuation no longer exists.
p = Path('v52/overtime-workflow-patch.txt')
s = p.read_text(encoding='utf-8')
s = s.replace("      'regular_day_off_overtime'\n", '')
s = s.replace("      'national_holiday_overtime',\n    ]", "      'national_holiday_overtime'\n    ]")
s = s.replace("      'national_holiday_overtime',\n      ]", "      'national_holiday_overtime'\n      ]")
if 'regular_day_off_overtime' in s:
    raise SystemExit('regular_day_off_overtime remains in workflow patch')
p.write_text(s, encoding='utf-8')

# Edit helper: no longer restore a removed regular-day type.
p = Path('v52/overtime-payroll-edit-fix-patch.txt')
s = p.read_text(encoding='utf-8')
s = s.replace("const newTypes=new Set(['rest_day_overtime','national_holiday_overtime','regular_day_off_overtime']);", "const newTypes=new Set(['rest_day_overtime','national_holiday_overtime']);")
if 'regular_day_off_overtime' in s:
    raise SystemExit('regular_day_off_overtime remains in payroll edit fix')
p.write_text(s, encoding='utf-8')

# Payroll summary: only current supported overtime day types remain.
p = Path('v52/overtime-payroll-summary-patch.txt')
s = p.read_text(encoding='utf-8')
s = s.replace("const timed=new Set(['overtime','holiday_overtime','rest_day_overtime','national_holiday_overtime','regular_day_off_overtime']);", "const timed=new Set(['overtime','holiday_overtime','rest_day_overtime','national_holiday_overtime']);")
if 'regular_day_off_overtime' in s:
    raise SystemExit('regular_day_off_overtime remains in payroll summary')
p.write_text(s, encoding='utf-8')

# Report every remaining runtime reference in one pass.
issues=[]
for q in Path('v52').glob('*.txt'):
    text = q.read_text(encoding='utf-8')
    for token in ('split_group_id','split_part','split_day_type_confirmed','next_day_request_type','regular_day_off_overtime'):
        if token in text:
            issues.append(f'{token} remains in {q}')
if issues:
    raise SystemExit('\n'.join(issues))

print('legacy cross-midnight frontend references removed')
