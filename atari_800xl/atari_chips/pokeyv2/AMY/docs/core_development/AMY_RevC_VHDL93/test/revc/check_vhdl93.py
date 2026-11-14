"""Conservative VHDL-93 language/style smoke checks. Not a substitute for an HDL compiler."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[2]
rtls = sorted(p for p in (ROOT / 'vhdl').glob('*.vhd') if not p.name.startswith('tb_'))
tests = [ROOT/'test/revc/tb_top93.vhd', ROOT/'test/revc/tb_ext_phase.vhd', ROOT/'test/revc/tb_ext_memory.vhd']
issues = []
for p in rtls + tests:
    s = re.sub(r'--[^\n]*', '', p.read_text())
    for pat, desc in [
        (r'\bprocess\s*\(\s*all\s*\)', 'process(all) is VHDL-2008'),
        (r'<<\s*signal\b', 'VHDL-2008 external name'),
        (r'\bstd\.env\b', 'VHDL-2008 std.env'),
        (r'\bto_hstring\s*\(', 'VHDL-2008 to_hstring'),
        (r'\bcontext\s+\w+\s+is\b', 'VHDL-2008 context declaration'),
    ]:
        if re.search(pat, s, re.I): issues.append(f'{p.relative_to(ROOT)}: {desc}')
    # Neither sequential conditional signal assignment nor the 2008 ternary
    # conditional expression may appear inside a process; concurrent `when`
    # outside processes is standard VHDL-93 and deliberately allowed.
    for m in re.finditer(r'(?m)^\s*(?:\w+\s*:\s*)?process\s*(?:\([^)]*\))?\s*(?:is\s*)?', s, re.I):
        end = re.search(r'\bend\s+process\b', s[m.end():], re.I)
        if end is None: continue
        body = s[m.end():m.end()+end.start()]
        if re.search(r'<=\s*[^;]*?\s+when\s+', body, re.I|re.S):
            issues.append(f'{p.relative_to(ROOT)}: conditional signal assignment inside process')
if issues: raise SystemExit('FAIL:\n'+'\n'.join(issues))
print('PASS: VHDL-93 static language checks on', len(rtls), 'RTL units and', len(tests), 'portable testbenches')
