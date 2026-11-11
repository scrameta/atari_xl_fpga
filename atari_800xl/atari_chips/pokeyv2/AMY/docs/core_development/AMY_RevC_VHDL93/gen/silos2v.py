#!/usr/bin/env python3
"""Translate the AMY1 SILOS deck (cell macros + netlist + .RAM/.ROM definitions
from a pattern file) into flat switch-level Verilog for Icarus.

Modelling choices (following the SILOS notes in the deck):
  * every signal net is a trireg, so dynamic (precharged / latched) nodes hold charge
  * NMOS-style gates (.NOR/n etc.) drive (pull1, strong0); plain gates (strong1, strong0)
  * gate delay = 1 time unit (one SILOS cycle = 5 ns), switches and pullups 0
  * .nmos between two signal nets -> tranif1 (bidirectional)
  * .nmos to .vcc / .gnd -> bufif1 strong source
  * .res to .vcc -> pullup(pull1); .res between nets -> rtran
  * .RAM -> behavioural, data driven at (pull1, pull0) while RE high (SILOS RAMs are resistive)
  * .ROM -> behavioural, transport delay
  * first-listed address/data signal = MSB (matches the deck's own comments)
"""
import re, sys
from collections import OrderedDict

mac_file, net_file, pat_file, out_file = sys.argv[1:5]
import os, hashlib
INITSEED = os.environ.get('INITSEED')
def initbit(n):
    return hashlib.sha256((INITSEED + ':' + n).encode()).digest()[0] & 1
fixes = set(sys.argv[5:])

def logical_lines(path, keep_comment_cont=False):
    out = []
    for raw in open(path, encoding='latin-1'):
        line = raw.rstrip('\n')
        s = line.lstrip()
        if s.startswith('$'):
            continue
        line = line.split('$', 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith('+'):
            if out:
                out[-1] += ' ' + line[1:]
            continue
        out.append(line)
    return out

def esc(n):
    return '\\' + n + ' '

SUPPLY = {'.VCC': 'VCC', 'VCC': 'VCC', '.GND': 'GND', 'GND': 'GND'}

macros = {}
cur = None
for l in logical_lines(mac_file):
    t = l.split()
    if t[0].upper() == '.MACRO':
        cur = t[1].upper()
        macros[cur] = {'ports': [p.upper() for p in t[2:]], 'body': []}
    elif t[0].upper() == '.EOM':
        cur = None
    elif cur:
        macros[cur]['body'].append(l)

nets = set()
lines = []
devs = []
mems_info = []
inits = []
cnt = [0]

def uid(p):
    cnt[0] += 1
    return f'{p}{cnt[0]}'

GATES = {'.INV': 'not', '.NOR': 'nor', '.NAND': 'nand', '.AND': 'and', '.OR': 'or',
         '.XOR': 'xor', '.BUF': 'buf'}

def N(n):
    n = n.upper()
    if n in SUPPLY:
        return SUPPLY[n]
    nets.add(n)
    return n

def emit_prim(inst, typ, args, ren):
    T = typ.upper()
    base, _, mod = T.partition('/')
    if base in GATES:
        st = '(pull1, strong0)' if mod == 'N' else '(strong1, strong0)'
        out = N(ren(inst))
        ins = [N(ren(a)) for a in args]
        conn = ', '.join(esc(x) if x not in ('VCC', 'GND') else x for x in [out] + ins)
        lines.append(f'  {GATES[base]} {st} #(1,0) {uid("g")} ({conn});')
        devs.append(('g', base, out, ins))
        return True
    if base == '.NMOS':
        g, a, b = (N(ren(x)) for x in args[:3])
        def e(x): return x if x in ('VCC', 'GND') else esc(x)
        if a in ('VCC', 'GND') and b in ('VCC', 'GND'):
            return True
        if a in ('VCC', 'GND') or b in ('VCC', 'GND'):
            sup, node = (a, b) if a in ('VCC', 'GND') else (b, a)
            devs.append(('s', sup, node, [g]))
            if sup == 'VCC':
                lines.append(f'  bufif1 (pull1, highz0) {uid("pu")} ({e(node)}, 1\'b1, {e(g)});')
            else:
                lines.append(f'  bufif1 (highz1, strong0) {uid("pd")} ({e(node)}, 1\'b0, {e(g)});')
            return True
        lines.append(f'  tranif1 {uid("t")} ({e(a)}, {e(b)}, {e(g)});')
        devs.append(('t', g, a, [b]))
        return True
    if base == '.RES':
        a = N(ren(inst)); b = N(ren(args[0]))
        if b == 'VCC' or a == 'VCC':
            node = a if b == 'VCC' else b
            lines.append(f'  pullup (pull1) {uid("r")} ({esc(node)});')
            devs.append(('pu', None, node, []))
        elif b == 'GND' or a == 'GND':
            node = a if b == 'GND' else b
            lines.append(f'  pulldown (pull0) {uid("r")} ({esc(node)});')
        else:
            lines.append(f'  tran {uid("rt")} ({esc(a)}, {esc(b)});')
            devs.append(('r', None, a, [b]))
        return True
    return False

def body_items(blines):
    for l in blines:
        t = l.split()
        if t[0].startswith('.'):
            yield None, t[0].upper(), t[1:]
        else:
            yield t[0].lstrip('('), t[1], [x for x in t[2:] if not re.fullmatch(r'\d+', x)]

def expand(items, ren):
    for inst, typ, args in items:
        if inst is None:
            if typ == '.INIT':
                for a in args:
                    n, _, v = a.partition('=')
                    inits.append((ren(n), v))
            continue
        U = typ.upper()
        # fixnzinit: the NOISE page re-derives NZINIT from NZINITN (XCMP209) under the same
        # name as the SEQCONT DREG output, so the net has two drivers that latch each other
        # and the DREG can never change it: Write Noise RAM never completes. Drop the copy.
        if ('fixnzinit' in fixes and inst is not None and ren(inst) == 'NZINIT'
                and U.startswith('.INV') and [ren(a) for a in args] == ['NZINITN']):
            continue
        if U.startswith('.'):
            if not emit_prim(inst, typ, args, ren):
                raise SystemExit(f'unknown primitive {typ} at {inst}')
            continue
        mac = macros[U]
        pmap = {p: ren(a) for p, a in zip(mac['ports'], args)}
        pre = ren(inst) + '.'
        def r2(n, pmap=pmap, pre=pre):
            u = n.upper()
            if u in SUPPLY:
                return u
            return pmap.get(u, pre + u)
        expand(list(body_items(mac['body'])), r2)

def top(n):
    return n.upper()

# the schematic block of each top-level line ($ NOISE1 ... -> NOISE); untagged lines inherit
BLOCKS = ('SEQCONT', 'XROM', 'ENVGEN', 'BUS', 'NOISE', 'PHASE', 'ACC', 'SINROM')
def block_lines(path):
    out = []; blk = None
    for raw in open(path, encoding='latin-1'):
        line = raw.rstrip('\n')
        s_ = line.lstrip()
        if s_.startswith('$'):
            continue
        code, _, com = line.partition('$')
        m = re.match(r'\s*([A-Z]+?)\s?(\d*)\b', com)
        if m and m.group(1) in BLOCKS:
            blk = m.group(1)
            if blk == 'SEQCONT' and m.group(2):      # the sequencer split by schematic page
                blk = 'SEQCONT' + m.group(2)[0]
        code = code.rstrip()
        if not code.strip():
            continue
        if code.startswith('+'):
            if out: out[-1] = (out[-1][0] + ' ' + code[1:], out[-1][1])
            continue
        out.append((code, blk))
    return out
devsec = []
for code, blk in block_lines(net_file):
    n0 = len(devs)
    expand(list(body_items([code])), top)
    devsec += [blk] * (len(devs) - n0)
assert len(devsec) == len(devs)

# ---- memories from the pattern deck
mem_mods = []
mem_insts = []
for l in logical_lines(pat_file):
    t = l.split()
    if len(t) < 2 or t[1].upper() not in ('.RAM', '.ROM'):
        continue
    name, kind = t[0].upper(), t[1].upper()
    rest = t[2:]
    nums = []
    while rest and re.fullmatch(r'\d+', rest[0]):
        nums.append(int(rest.pop(0)))
    sig = []
    entries = []
    for x in rest:
        if '/' in x and re.fullmatch(r'[0-9A-Fa-f?]*/[0-9A-Fa-f?]*', x) and x != '/':
            entries.append(x)
        else:
            sig.append(x)
    s = ' '.join(sig)
    left, _, right = s.partition('/')
    lt = left.split(); dt = right.split()
    if kind == '.RAM':
        rd, wd = nums[0], nums[1]
        re_n, we_n = lt[0], lt[1]
        addr = lt[2:]
    else:
        rd = nums[0]; wd = 0
        addr = lt
    data = dt
    if name == 'NOISE' and 'fixnoise' in fixes and [d.upper() for d in data] == ['NZIO2', 'NZIO1', 'NZIO1']:
        data = ['nzio2', 'nzio1', 'nzio0']
    AW, DW = len(addr), len(data)
    # radix of contents: RAM entries are binary in this deck, ROM entries hex
    radix = 2 if kind == '.RAM' else 16
    init = []
    for e in entries:
        a, d = e.split('/')
        init.append((a, d))
    mname = f'mem_{name}'
    body = [f'module {mname} (']
    ports = []
    if kind == '.RAM':
        ports += ['input re', 'input we']
    ports += [f'input [{AW-1}:0] a']
    ports += [f'inout [{DW-1}:0] d' if kind == '.RAM' else f'output [{DW-1}:0] d']
    body.append('  ' + ',\n  '.join(ports) + ');')
    depth = 1 << AW
    body.append(f'  reg [{DW-1}:0] m [0:{depth-1}];')
    body.append('  integer i;')
    body.append('  initial begin')
    # unlisted ROM words read as 0 (only XROMBS is partial: 96 of 128 words, the rest is
    # the fully-attenuated region); RAMs power up unknown
    fill = '0' if kind == '.ROM' else 'x'
    body.append(f"    for (i = 0; i < {depth}; i = i + 1) m[i] = {DW}'b{fill};")
    # wildcard entries first, specific entries override
    def conv(val, bits, rad):
        if rad == 2:
            return val
        v = int(val, 16)
        return format(v, f'0{bits}b')[-bits:]
    wild = [(a, d) for a, d in init if '?' in a]
    spec = [(a, d) for a, d in init if '?' not in a]
    for a, d in wild:
        dbits = conv(d, DW, radix) if '?' not in d else None
        if dbits is None:
            continue
        # expand wildcard pattern over address space
        abits = a if radix == 2 else None
        if abits is None:
            continue
        pat = abits.rjust(AW, '0')
        body.append(f"    for (i = 0; i < {depth}; i = i + 1) if (match_{name}(i)) m[i] = {DW}'b{dbits};")
        wild_pat = pat
    for a, d in spec:
        if radix == 2:
            ai = int(a, 2)
        else:
            ai = int(a, 16)
        if ai >= depth:
            continue
        body.append(f"    m[{ai}] = {DW}'b{conv(d, DW, radix)};")
    body.append('  end')
    if wild:
        pat = wild[0][0].rjust(AW, '?')
        conds = []
        for bi, ch in enumerate(pat):
            bitpos = AW - 1 - bi
            if ch in '01':
                conds.append(f'(v[{bitpos}] == 1\'b{ch})')
        cond = ' && '.join(conds) if conds else "1'b1"
        body.append(f'  function match_{name}; input [{AW-1}:0] v; match_{name} = {cond}; endfunction')
    if kind == '.ROM':
        body.append(f'  reg [{DW-1}:0] q;')
        body.append(f"  initial q = {DW}'bx;")
        body.append(f'  always @(a) q <= #{rd} ((^a) === 1\'bx) ? {DW}\'bx : m[a];')
        body.append('  assign d = q;')
    else:
        body.append(f'  reg [{DW-1}:0] q; reg wev;')
        body.append(f"  initial begin q = {DW}'bx; wev = 0; end")
        body.append(f'  always @(re or a or wev) q <= #{rd} ((^a) === 1\'bx) ? {DW}\'bx : m[a];')
        body.append(f'  assign (pull1, strong0) d = (re === 1\'b1 && we !== 1\'b1) ? q : {{{DW}{{1\'bz}}}};')
        # SILOS write delay treated as a minimum pulse/hold: data are committed only if WE was
        # high and address/data stable for >= WD units (a 1-unit overlap of WE with the bus
        # precharge must not overwrite the word)
        body.append(f'  reg [{DW-1}:0] dl; reg [{AW-1}:0] al; reg wel; time tl;')
        body.append("  initial begin wel = 0; tl = 0; end")
        body.append('  always @(we or a or d) begin')
        body.append(f'    if (wel === 1\'b1 && ($time - tl) >= {wd} && (^al) !== 1\'bx) begin m[al] = dl; wev = ~wev; end')
        body.append('    dl = d; al = a; wel = we; tl = $time;')
        body.append('  end')
    body.append('endmodule')
    mem_mods.append('\n'.join(body))

    def sigs(lst):
        out = []
        for x in lst:
            u = x.upper()
            if u in SUPPLY:
                out.append("1'b0" if SUPPLY[u] == 'GND' else "1'b1")
            else:
                out.append(esc(N(u)))
        return '{' + ', '.join(out) + '}'
    conn = []
    if kind == '.RAM':
        conn.append(f'.re({esc(N(re_n.upper()))})')
        conn.append(f'.we({esc(N(we_n.upper()))})')
    conn.append(f'.a({sigs(addr)})')
    conn.append(f'.d({sigs(data)})')
    devs.append(('m', name, [x.upper() for x in data], [x.upper() for x in addr] + ([re_n.upper(), we_n.upper()] if kind == '.RAM' else [])))
    mems_info.append(dict(name=name, kind=kind, rd=rd, wd=wd, re=(re_n.upper() if kind == '.RAM' else None), we=(we_n.upper() if kind == '.RAM' else None), addr=[x.upper() for x in addr], data=[x.upper() for x in data], init=init, radix=radix))
    mem_insts.append(f'  {mname} u_{name} (' + ', '.join(conn) + ');')

PINS_IN = ['A0', 'A1', 'CLOCK', 'CSN', 'OEN', 'RDN', 'RESETN', 'TEST', 'WRN']
PINS_OUT = ['INTRDY'] + [f'SAMP{i}' for i in range(16)]
PINS_IO = ['ALE', 'BOUTCSYNC', 'OUTSTBNT1', 'V0T0'] + [f'DB{i}' for i in range(8)]
pins = PINS_IN + PINS_OUT + PINS_IO
missing = [p for p in pins if p not in nets]
if missing:
    print('WARNING pins not found in netlist:', missing)

with open(out_file, 'w') as f:
    f.write('// Generated from the AMY1 SILOS deck by silos2v.py -- switch-level model\n')
    f.write('`timescale 1ns/1ns\n\n')
    for m in mem_mods:
        f.write(m + '\n\n')
    f.write('module amy1 (\n  ' + ',\n  '.join(
        [f'input {esc(p)}' for p in PINS_IN] +
        [f'output {esc(p)}' for p in PINS_OUT] +
        [f'inout {esc(p)}' for p in PINS_IO]) + ');\n')
    f.write('  supply1 VCC; supply0 GND;\n')
    f.write('  input init_en;\n' if False else '')
    for n in sorted(nets - set(pins)):
        if INITSEED is not None:
            f.write(f'  wire {esc(n)}; keeper #(.INIT({initbit(n)})) {uid("k")} ({esc(n)});\n')
        else:
            f.write(f'  wire {esc(n)}; keeper {uid("k")} ({esc(n)});\n')
    f.write('\n'.join(lines) + '\n')
    f.write('\n'.join(mem_insts) + '\n')
    # .init handling: temporary supply-strength driver for the first few time units
    f.write('  reg init_drv = 1;\n  initial #6 init_drv = 0;\n')
    for n, v in inits:
        n = n.upper()
        f.write(f"  assign (supply1, supply0) {esc(n)} = init_drv ? 1'b{v} : 1'bz;\n")
    f.write('endmodule\n')

import json; json.dump(devs, open(out_file + '.json', 'w')); json.dump(mems_info, open(out_file + '.mem.json', 'w'))
json.dump(devsec[:len(devs)] + [None] * (len(devs) - len(devsec)), open(out_file + '.blk.json', 'w'))
print(f'nets {len(nets)}, prims {len(lines)}, memories {len(mem_insts)}, inits {inits}')
