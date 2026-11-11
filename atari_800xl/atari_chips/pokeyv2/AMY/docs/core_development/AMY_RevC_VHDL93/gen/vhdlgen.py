#!/usr/bin/env python3
"""Generate the AMY1 core as VHDL from the flattened switch-level netlist.

usage: vhdlgen.py amy1.v.json amy1.v.mem.json SYNCHRO.NET outdir

Inputs are written by silos2v.py (device list and RAM/ROM definitions); SYNCHRO.NET is read
for the adder cells' carry ports. Outputs:
  amy1_core.vhd     the chip logic; one sequencer step per clk with step_en = '1'
  amy1_mem_pkg.vhd  memory geometry and initial contents (ROM tables, RAM power-up)
  amy1_mem.vhd      the memories: one synchronous-read block each (reference layout)

The model is the one rtlgen.py produces for Verilog, which was checked sample-for-sample
against the switch-level simulation:
  * The on-chip clock generator is replaced by a 6-step sequencer per internal chip clock
    (G1 PRECH | S2 CLK,PRECH | S3 CLK,T10 | G2 - | S0 CLKN | S1 CLKN,T10).
  * Nets driven only by a logic gate (or a ROM bit) are ordinary combinational signals.
  * Every other net - pass-transistor nodes, precharged nodes, wired buses, pads, RAM data -
    is resolved each step by the switch-level rule:
        a conducting path to a '0' source            -> '0'
        else a conducting path to a '1' source       -> '1'
        else the charge stored in the previous step  -> <net>_reg
    Paths are followed for up to KMAX switches, except the precharged adder carry chains,
    which are evaluated as a forward ripple (generate and propagate are exclusive).
  * Memories are external with a synchronous read: the address of step k gives data in
    step k+1; a write happens at the end of the step in which WE is high.
"""
import json, os, re, sys
from collections import defaultdict

KMAX = 2

CLOCKNETS = {'CLK', 'CLKN', 'PRECH', 'T10MHZ'}
SEQUENCE = {'PRECH': (0, 1), 'CLK': (1, 2), 'T10MHZ': (2, 5), 'CLKN': (4, 5)}
PINS_IN = ['A0', 'A1', 'CLOCK', 'CSN', 'OEN', 'RDN', 'RESETN', 'TEST', 'WRN']
PINS_IO = ['ALE', 'BOUTCSYNC', 'OUTSTBNT1', 'V0T0'] + [f'DB{i}' for i in range(8)]
SUP = {'VCC', 'GND'}

VHDL_KEYWORDS = set('''abs access after alias all and architecture array assert attribute begin
block body buffer bus case component configuration constant disconnect downto else elsif end
entity exit file for function generate generic group guarded if impure in inertial inout is label
library linkage literal loop map mod nand new next nor not null of on open or others out package
port postponed procedure process pure range record register reject rem report return rol ror
select severity signal shared sla sll sra srl subtype then to transport type unaffected units
until use variable wait when while with xnor xor'''.split())


# =============================================================================== netlist
class Netlist:
    """Channel-connected structure of the chip, as needed for the step model."""

    def __init__(self, devs, mems, synchro):
        self.mems = mems
        # the clock generator's outputs become sequencer outputs
        devs = [d for d in devs if not (d[0] in ('g', 's') and d[2] in CLOCKNETS)]

        self.gate_of = {}                         # net -> (type, inputs)
        self.extra_gates = defaultdict(list)      # nets with more than one gate driver
        self.pull = defaultdict(list)             # net -> [('VCC'|'GND', gate) | ('PULL', None)]
        self.edges = []                           # switches: (gate or None = always on, a, b)
        chan = set()
        for d in devs:
            k = d[0]
            if k in ('t', 'r'):
                a, b = d[2], d[3][0]
                chan |= {a, b}
                if k == 'r' or d[1] == 'VCC':
                    self.edges.append((None, a, b))
                elif d[1] != 'GND':
                    self.edges.append((d[1], a, b))
            elif k == 's':
                self.pull[d[2]].append((d[1], d[3][0])); chan.add(d[2])
            elif k == 'pu':
                self.pull[d[2]].append(('PULL', None)); chan.add(d[2])
        for d in devs:
            if d[0] == 'g':
                if d[2] in self.gate_of:
                    self.extra_gates[d[2]].append((d[1], d[3])); chan.add(d[2])
                else:
                    self.gate_of[d[2]] = (d[1], d[3])

        self.rom_bit = {}                         # ROM data net -> (memory, bit)
        self.ram_bit = defaultdict(list)          # RAM data net -> [(memory, bit)]
        for m in mems:
            dw = len(m['data'])
            for i, n in enumerate(m['data']):
                if m['kind'] == '.ROM':
                    self.rom_bit[n] = (m['name'], dw - 1 - i)
                else:
                    self.ram_bit[n].append((m['name'], dw - 1 - i)); chan.add(n)
        chan |= set(PINS_IO)
        self.chan = chan

        self.carry_nets, self.con_of = set(), {}
        for line in open(synchro, encoding='latin-1'):
            t = line.split('$')[0].split()
            if len(t) < 3:
                continue
            ty, args, inst = t[1].upper(), [x.upper() for x in t[2:]], t[0].lstrip('(').upper()
            if ty == 'FADD' and len(args) >= 5:
                self.carry_nets.add(args[4]); self.con_of[inst] = args[4]
            elif ty in ('HADD', 'ADD') and len(args) >= 4:
                self.carry_nets.add(args[3]); self.con_of[inst] = args[3]

        self.boundary = sorted(n for n in chan if self.is_boundary(n))
        self.resolved = sorted(n for n in chan if not self.is_boundary(n))
        self._networks()

    def is_boundary(self, n):
        """Driven only by one gate or one ROM bit: plain combinational value."""
        if n in self.extra_gates or n in self.pull or n in self.ram_bit or n in PINS_IO:
            return False
        return n in self.gate_of or n in self.rom_bit

    def _networks(self):
        rset = set(self.resolved)
        par = {n: n for n in self.resolved}

        def root(x):
            while par[x] != x:
                par[x] = par[par[x]]; x = par[x]
            return x
        for g, a, b in self.edges:
            if a in rset and b in rset:
                par[root(a)] = root(b)
        inner = defaultdict(list)
        self.outer = defaultdict(list)            # resolved net -> [(gate, boundary net)]
        for g, a, b in self.edges:
            if a in rset and b in rset:
                inner[root(a)].append((g, a, b))
            elif a in rset:
                self.outer[a].append((g, b))
            elif b in rset:
                self.outer[b].append((g, a))
        groups = defaultdict(list)
        for n in self.resolved:
            groups[root(n)].append(n)
        self.networks = sorted(((sorted(v), inner.get(r, [])) for r, v in groups.items()),
                               key=lambda x: x[0][0])

    def ripple(self, nets, sw):
        """Adder carry chain: switches oriented cin -> con and nets in ripple order, or None."""
        if not (set(nets) & self.carry_nets):
            return None
        fwd = []
        for g, a, b in sw:
            con = self.con_of.get(g.split('.')[0] if g and '.' in g else None)
            if con == b:
                fwd.append((g, a, b))
            elif con == a:
                fwd.append((g, b, a))
            else:
                return None
        indeg, nxt = defaultdict(int), defaultdict(list)
        for g, a, b in fwd:
            indeg[b] += 1; nxt[a].append(b)
        order, todo = [], [n for n in nets if indeg[n] == 0]
        while todo:
            x = todo.pop(); order.append(x)
            for b in nxt[x]:
                indeg[b] -= 1
                if indeg[b] == 0:
                    todo.append(b)
        return (order, fwd) if len(order) == len(nets) else None

    def depth(self, nets, sw):
        """Number of propagation rounds needed (graph diameter for a tree, N-1 otherwise)."""
        if not sw:
            return 0
        if len(sw) != len(nets) - 1:
            d = len(nets) - 1
        else:
            adj = defaultdict(set)
            for g, a, b in sw:
                adj[a].add(b); adj[b].add(a)

            def far(s):
                dist, q = {s: 0}, [s]
                for x in q:
                    for y in adj[x]:
                        if y not in dist:
                            dist[y] = dist[x] + 1; q.append(y)
                f = max(dist, key=dist.get)
                return f, dist[f]
            d = far(far(nets[0])[0])[1]
        if not (set(nets) & self.carry_nets):
            d = min(d, KMAX)
        return d


# =============================================================================== naming
class Names:
    """Schematic net name -> legal, unique VHDL identifier (VHDL is case-insensitive)."""
    RENAME = {'CLK': 'CLK_PH', 'CLKN': 'CLKN_PH'}

    def __init__(self, reserved):
        self.map, self.used = {}, {r.lower() for r in reserved}

    def __call__(self, n):
        if n in self.map:
            return self.map[n]
        v = self.RENAME.get(n, n)
        v = re.sub(r'[^A-Za-z0-9]+', '_', v).strip('_')
        if not v or not v[0].isalpha():
            v = 'N_' + v
        if v.lower() in VHDL_KEYWORDS:
            v += '_N'
        base, k = v, 1
        while v.lower() in self.used:
            v = f'{base}_{k}'; k += 1
        self.used.add(v.lower()); self.map[n] = v
        return v


def mem_ident(m):
    return m['name'].lower()


def mem_words(m):
    """Initial contents as a list of bit strings (wildcard rows first, then exact rows)."""
    aw, dw = len(m['addr']), len(m['data'])
    words = ['0' * dw] * (1 << aw)

    def bits(v):
        return v if m['radix'] == 2 else format(int(v, 16), f'0{dw}b')[-dw:]
    for a, v in m['init']:
        if '?' in a:
            pat = a.rjust(aw, '?')
            for i in range(len(words)):
                ib = format(i, f'0{aw}b')
                if all(p == '?' or p == c for p, c in zip(pat, ib)):
                    words[i] = bits(v)
    for a, v in m['init']:
        if '?' not in a:
            i = int(a, 2) if m['radix'] == 2 else int(a, 16)
            if i < len(words):
                words[i] = bits(v)
    return words


# =============================================================================== core
CORE_PORTS = '''\
    clk          : in  std_logic;
    step_en      : in  std_logic;                      -- advance one sequencer step

    -- chip pins (active low as on the real part; CLOCK is replaced by step_en)
    pin_resetn   : in  std_logic;
    pin_test     : in  std_logic;
    pin_oen      : in  std_logic;
    pin_csn      : in  std_logic;
    pin_wrn      : in  std_logic;
    pin_rdn      : in  std_logic;
    pin_a        : in  std_logic_vector(1 downto 0);
    pin_db_in    : in  std_logic_vector(7 downto 0);
    pin_db_drive : in  std_logic;                      -- host is driving DB
    pin_db_out   : out std_logic_vector(7 downto 0);
    pin_db_oe    : out std_logic_vector(7 downto 0);
    pin_intrdy   : out std_logic;                      -- READY mode: low while a command runs
    pin_samp     : out std_logic_vector(15 downto 0);  -- SAMP0 is muxed with bit 16 on the pin
    pin_outstbn  : out std_logic;                      -- OUTSTBN/T1 pad
    pin_v0       : out std_logic;                      -- V0/T0 pad: voice 0 (INDIVIDUAL mode)

    -- internal 17-bit sample latch (use this rather than pin_samp)
    samp_latch   : out std_logic_vector(16 downto 0);
    samp_load    : out std_logic;                      -- LDSAMP: latch is being loaded
    noise_init   : out std_logic;                      -- NZINIT: the host is loading the Noise RAM
'''


class CoreWriter:
    def __init__(self, nl):
        self.nl = nl
        reserved = ['clk', 'step_en', 'step_reg', 'step_next', 'pin_resetn', 'pin_test', 'pin_oen',
                    'pin_csn', 'pin_wrn', 'pin_rdn', 'pin_a', 'pin_db_in', 'pin_db_drive',
                    'pin_db_out', 'pin_db_oe', 'pin_intrdy', 'pin_samp', 'pin_outstbn', 'pin_v0',
                    'samp_latch', 'samp_load', 'noise_init']
        for m in nl.mems:
            mi = mem_ident(m)
            reserved += [f'{mi}_addr', f'{mi}_q', f'{mi}_we', f'{mi}_wdata', f'{mi}_rd']
        self.name = Names(reserved)
        self.decl, self.body, self.regs = [], [], []
        self.declared = set()
        self.ext = {}
        self.nterms = 0
        self.plan = None                 # stepcut.Plan: reads that use last step's value

    # ---- helpers
    def sig(self, n):
        if n in ('VCC', '.VCC'):
            return "'1'"
        if n in ('GND', '.GND'):
            return "'0'"
        return self.name(n)

    def declare(self, ident, init=None):
        if ident.lower() in self.declared:
            return
        self.declared.add(ident.lower())
        self.decl.append(f'  signal {ident} : std_logic' + (f" := '{init}'" if init else '') + ';')

    def net(self, n):
        v = self.sig(n); self.declare(v); return v

    def rd(self, c, x):
        """How consumer c reads signal x (see stepcut: x, x_reg or a latch's x_pre)."""
        if self.plan is not None and isinstance(x, str) and x not in SUP:
            if (c, x) in self.plan.cut:
                return f'{self.sig(x)}_reg'
            if (c, x) in self.plan.pre:
                return f'{self.sig(x)}_pre'
        return self.sig(x)

    def gate(self, t, ins, c=None):
        return self.expr(t, [self.rd(c, i) for i in ins])

    @staticmethod
    def expr(t, terms):
        if t == '.INV':
            return f'not {terms[0]}'
        op = 'and' if t in ('.AND', '.NAND') else 'or'
        e = f' {op} '.join(terms)
        if t in ('.NAND', '.NOR'):
            return f'not ({e})'
        return f'({e})' if len(terms) > 1 else e

    def rom_q(self, n):
        mname, b = self.nl.rom_bit[n]
        return f'{mname.lower()}_q({b})'

    def through(self, g, e, c=None):
        return e if g is None else f'({self.rd(c, g)} and {e})'

    def emit(self, *lines):
        self.body.extend(lines)

    @staticmethod
    def vec(items):
        return f'(0 => {items[0]})' if len(items) == 1 else ' & '.join(items)

    def section(self, *title):
        self.emit('  ' + '-' * 76, *[f'  -- {t}' for t in title], '  ' + '-' * 76)

    # ---- sections
    def sequencer(self):
        self.section('Step sequencer (replaces the on-chip two-phase clock generator)',
                     '  step 0  G1  PRECH            step 3  G2  -',
                     '  step 1  S2  CLK, PRECH       step 4  S0  CLKN',
                     '  step 2  S3  CLK, T10MHZ      step 5  S1  CLKN, T10MHZ')
        self.emit("  step_next <= (others => '0') when step_reg = 5 else step_reg + 1;", '')
        for n in ('PRECH', 'CLK', 'T10MHZ', 'CLKN'):
            a, b = SEQUENCE[n]
            self.emit(f"  {self.net(n):<8} <= '1' when step_reg = {a} or step_reg = {b} else '0';")
        self.emit('')

    def pins(self):
        nl = self.nl
        self.section('Pins')
        src = {'A0': 'pin_a(0)', 'A1': 'pin_a(1)', 'CSN': 'pin_csn', 'WRN': 'pin_wrn',
               'RDN': 'pin_rdn', 'RESETN': 'pin_resetn', 'TEST': 'pin_test', 'OEN': 'pin_oen',
               'CLOCK': "'0'"}
        for p in PINS_IN:
            self.emit(f'  {self.net(p):<8} <= {src[p]};')
        for p in PINS_IO:
            drv = f'drive_{self.sig(p)}'
            self.declare(drv)
            terms = [self.sig(g) for k, g in nl.pull.get(p, []) if k in SUP]
            self.emit(f"  {drv} <= {' or '.join(terms) if terms else chr(39) + '0' + chr(39)};"
                      '   -- chip drives the pad')
            if p.startswith('DB'):
                i = int(p[2:])
                self.ext[p] = (f'(pin_db_drive and not {drv})', f'pin_db_in({i})')
                self.emit(f'  pin_db_out({i}) <= {self.net(p)};',
                          f'  pin_db_oe({i})  <= {drv};')
        self.emit('')

    def gates(self):
        self.section('Logic gates')
        for n, (t, ins) in sorted(self.nl.gate_of.items()):
            if n in self.nl.chan:
                continue
            self.emit(f'  {self.net(n)} <= {self.gate(t, ins, n)};')
        self.emit('')

    def memories(self):
        self.section('Memory interface: address in step k, data back in step k+1;',
                     'a RAM write happens at the end of the step in which WE is high.')
        for m in self.nl.mems:
            mi = mem_ident(m)
            self.emit(f'  -- {m["kind"][1:]} {m["name"]}: {1 << len(m["addr"])} x {len(m["data"])}')
            self.emit(f'  {mi}_addr <= {self.vec([self.sig(a) for a in m["addr"]])};')
            if m['kind'] == '.RAM':
                self.declare(f'{mi}_rd')
                self.emit(f'  {mi}_we <= {self.sig(m["we"])};',
                          f'  {mi}_wdata <= {self.vec([self.net(d) for d in m["data"]])};',
                          f'  {mi}_rd <= {self.sig(m["re"])} and not {self.sig(m["we"])};'
                          '   -- RAM drives its data lines')
            else:
                for d in m['data']:
                    if d.lstrip('.') in SUP or d in self.nl.chan:
                        continue
                    self.emit(f'  {self.net(d)} <= {self.rom_q(d)};')
            self.emit('')

    def networks(self):
        nl = self.nl
        self.section('Switch networks',
                     "z*_<net>: path to a '0' source, o*_<net>: path to a '1' source.",
                     'A net with neither keeps the charge it held in the previous step (_reg).')
        for n in nl.boundary:      # gate/ROM outputs that also touch a switch
            if n in nl.gate_of:
                self.emit(f'  {self.net(n)} <= {self.gate(*nl.gate_of[n], n)};')
            else:
                self.emit(f'  {self.net(n)} <= {self.rom_q(n)};')
        self.emit('')
        for i, (nets, sw) in enumerate(nl.networks):
            names = ', '.join(nets[:5]) + (', ...' if len(nets) > 5 else '')
            self.emit(f'  -- network {i}: {len(nets)} net(s), {len(sw)} switch(es): {names}')
            for n in nets:
                self._sources(n, i)
            rip = nl.ripple(nets, sw)
            if rip is not None:
                last = self._ripple(*rip, i)
            else:
                last = self._rounds(nets, sw, nl.depth(nets, sw), i)
            for n in nets:
                v = self.net(n)
                reg = f'{v}_reg'
                self.declare(reg, '0')
                self.emit(f"  {v} <= '0' when z{last}_{v} = '1' else '1' when o{last}_{v} = '1' else {reg};")
                self.regs.append((reg, v))
            self.emit('')

    def _sources(self, n, i):
        """Round 0: the direct 0 and 1 sources of net n (in network i)."""
        nl, sig, c = self.nl, self.sig, ('N', i)
        z, o = [], []
        drivers = [nl.gate_of[n]] if n in nl.gate_of else []
        for g in drivers + nl.extra_gates.get(n, []):
            e = self.gate(*g, c)
            z.append(f'not ({e})'); o.append(f'({e})')
        if n in nl.rom_bit:
            q = self.rom_q(n); z.append(f'not {q}'); o.append(q)
        for kind, g in nl.pull.get(n, []):
            if kind == 'PULL':
                o.append("'1'")
            elif kind == 'VCC':
                o.append(self.rd(c, g))
            else:
                z.append(self.rd(c, g))
        for mname, b in nl.ram_bit.get(n, []):
            mi = mname.lower()
            z.append(f'({mi}_rd and not {mi}_q({b}))'); o.append(f'({mi}_rd and {mi}_q({b}))')
        if n in self.ext:
            en, val = self.ext[n]
            z.append(f'({en} and not {val})'); o.append(f'({en} and {val})')
        for g, b in nl.outer.get(n, []):
            bv = self.rd(('N', i, n, g, b), b)
            z.append(self.through(g, f'not {bv}', c)); o.append(self.through(g, bv, c))
        v = sig(n)
        for p, terms in (('z0', z), ('o0', o)):
            self.declare(f'{p}_{v}')
            self.emit(f"  {p}_{v} <= {' or '.join(terms) if terms else chr(39) + '0' + chr(39)};")

    def _rounds(self, nets, sw, k_max, i):
        sig = self.sig
        adj = defaultdict(list)
        for g, a, b in sw:
            adj[a].append((g, b)); adj[b].append((g, a))
        for k in range(1, k_max + 1):
            for n in nets:
                v = sig(n)
                for p in ('z', 'o'):
                    terms = [f'{p}{k-1}_{v}'] + [self.through(g, f'{p}{k-1}_{sig(m)}', ('N', i)) for g, m in adj[n]]
                    self.declare(f'{p}{k}_{v}')
                    self.emit(f"  {p}{k}_{v} <= {' or '.join(terms)};")
                    self.nterms += len(terms)
        return str(k_max)

    def _ripple(self, order, fwd, i):
        sig = self.sig
        back = defaultdict(list)
        for g, a, b in fwd:
            back[b].append((g, a))
        self.emit('  -- carry chain: evaluated as a forward ripple')
        for n in order:
            v = sig(n)
            for p in ('z', 'o'):
                terms = [f'{p}0_{v}'] + [self.through(g, f'{p}r_{sig(a)}', ('N', i)) for g, a in back[n]]
                self.declare(f'{p}r_{v}')
                self.emit(f"  {p}r_{v} <= {' or '.join(terms)};")
                self.nterms += len(terms)
        return 'r'

    def held(self):
        """Gate outputs read as last step's value, and the cross-coupled latches."""
        if self.plan is None:
            return
        self.section('Last-step values of gate outputs (where a loop is cut), and',
                     'cross-coupled latches: b_pre is b evaluated from the latch state a_reg,',
                     'so a and b below are the latch\'s settled values for this step.')
        for b in self.plan.regs:
            reg = f'{self.sig(b)}_reg'
            self.declare(reg, '0')
            self.regs.append((reg, self.sig(b)))
        nl = self.nl
        for a, b in self.plan.latch:
            members = {a} if isinstance(a, str) else set(nl.networks[a[1]][0])
            t, ins = nl.gate_of[b]
            terms = [f'{self.sig(x)}_reg' if x in members else self.rd(b, x) for x in ins]
            pre = f'{self.sig(b)}_pre'
            self.declare(pre)
            self.emit(f'  {pre} <= {self.expr(t, terms)};')
        self.emit('')

    def outputs(self):
        s = self.sig
        self.section('Outputs')
        self.emit(f'  pin_intrdy  <= {s("INTRDY")};',
                  f'  pin_outstbn <= {s("OUTSTBNT1")};',
                  f'  pin_v0      <= {s("V0T0")};',
                  '  pin_samp    <= ' + ' & '.join(s(f'SAMP{i}') for i in range(15, -1, -1)) + ';',
                  '  samp_latch  <= ' + ' & '.join(s(f'SAMP{i}L') for i in range(16, -1, -1)) + ';',
                  f'  samp_load   <= {s("LDSAMP")};',
                  f'  noise_init  <= {s("NZINIT")};', '')

    def registers(self):
        self.section('Registers: the sequencer step and the charge held on every dynamic net')
        self.emit('  process (clk)', '  begin', '    if rising_edge(clk) then',
                  "      if step_en = '1' then",
                  '        step_reg <= step_next;')
        for reg, v in self.regs:
            self.emit(f'        {reg} <= {v};')
        self.emit('      end if;', '    end if;', '  end process;', '')

    def write(self, path):
        self.sequencer(); self.pins(); self.gates(); self.memories()
        self.networks(); self.held(); self.outputs(); self.registers()
        mp = []
        for m in self.nl.mems:
            mi, aw, dw = mem_ident(m), len(m['addr']), len(m['data'])
            mp.append(f'    {mi}_addr : out std_logic_vector({aw - 1} downto 0);')
            if m['kind'] == '.RAM':
                mp.append(f'    {mi}_we : out std_logic;')
                mp.append(f'    {mi}_wdata : out std_logic_vector({dw - 1} downto 0);')
            mp.append(f'    {mi}_q : in  std_logic_vector({dw - 1} downto 0);')
        mp[-1] = mp[-1][:-1]
        text = [
            '-------------------------------------------------------------------------------',
            '-- AMY1 additive synthesizer core',
            '--',
            '-- Generated by vhdlgen.py from the AMY1 version 3 netlist (SYNCHRO.NET and',
            '-- ADJUSTED.MAC, Atari 1984-85). Do not edit; regenerate instead.',
            '--',
            '-- One sequencer step per clk with step_en = 1. Six steps make one internal chip',
            '-- clock, which is two cycles of the original CLOCK input: for an 8 MHz AMY run',
            '-- 24 MHz of steps. One output sample every 128 internal clocks (64 harmonics).',
            '--',
            '-- Signal names are the schematic net names (X<cell>_X<node> inside cells).',
            '-- For each dynamic net, <net> is its value in the current step (next state) and',
            '-- <net>_reg the charge it held at the end of the previous step (register).',
            '-------------------------------------------------------------------------------',
            'library ieee;', 'use ieee.std_logic_1164.all;', 'use ieee.numeric_std.all;', '',
            'entity amy1_core is', '  port (', CORE_PORTS, '    -- memories (see amy1_mem)',
            *mp, '  );', 'end entity;', '',
            'architecture rtl of amy1_core is',
            "  signal step_reg  : unsigned(2 downto 0) := (others => '0');",
            '  signal step_next : unsigned(2 downto 0);', '']
        text += self.decl + ['', 'begin', ''] + self.body + ['end architecture;', '']
        open(path, 'w').write('\n'.join(text))


# =============================================================================== memories
LOAD_AW = 11          # load address bits: every memory word is one 32-bit image word

# RAMs that share an address are stored as one word (fields from bit 0 up), so that the
# packed memory layout can keep each group in a single block RAM.
GROUPS = {'HARM': ['HARMBRKPOINT', 'HARMCURNTVAL', 'LHPRAM'], 'VOICE': ['VOICE18', 'VOICE3']}


def load_map(mems):
    """Image layout: units (a memory, or a group of memories sharing an address) largest
    first, each at a base aligned to its size. Returns ([(unit, aw, base, [(m, lsb)])], total)."""
    by_name = {m['name']: m for m in mems}
    grouped = {n for ns in GROUPS.values() for n in ns}
    units = [(g, [by_name[n] for n in ns]) for g, ns in GROUPS.items()]
    units += [(m['name'], [m]) for m in mems if m['name'] not in grouped]
    out, base = [], 0
    for name, ms in sorted(units, key=lambda u: (-len(u[1][0]['addr']), u[0])):
        aw = len(ms[0]['addr'])
        assert all(m['addr'] == ms[0]['addr'] for m in ms), name
        fields, lsb = [], 0
        for m in ms:
            fields.append((m, lsb)); lsb += len(m['data'])
        assert lsb <= 32
        out.append((name, aw, base, fields))
        base += 1 << aw
    assert base <= 1 << LOAD_AW
    return out, base


def write_image(mems, outdir):
    """amy1_mem.bin (32-bit little endian words) and amy1_mem.hex (one word per line)."""
    lm, total = load_map(mems)
    words = [0] * total
    for name, aw, base, fields in lm:
        for m, lsb in fields:
            for i, w in enumerate(mem_words(m)):
                words[base + i] |= int(w, 2) << lsb
    with open(os.path.join(outdir, 'amy1_mem.bin'), 'wb') as f:
        for w in words:
            f.write(w.to_bytes(4, 'little'))
    with open(os.path.join(outdir, 'amy1_mem.hex'), 'w') as f:
        for w in words:
            f.write(f'{w:08x}\n')
    return total


def write_mem_pkg(mems, path):
    lm, total = load_map(mems)
    L = ['-------------------------------------------------------------------------------',
         '-- AMY1 memory geometry and load image layout. Generated by vhdlgen.py.',
         '--',
         '-- Nothing is initialised by the FPGA configuration (MAX 10 compact parts cannot).',
         '-- All memories, ROM tables included, are written through the load port from the',
         '-- image amy1_mem.bin: one 32-bit word per address of each unit, at <UNIT>_BASE.',
         '-- A unit is a memory, or a group of RAMs sharing an address (HARM, VOICE) whose',
         '-- word holds each member at <NAME>_LSB. ROM tables are from the 1985 SILOS deck;',
         "-- RAMs get the deck's power-up values.",
         '-------------------------------------------------------------------------------',
         'library ieee;', 'use ieee.std_logic_1164.all;', '', 'package amy1_mem_pkg is',
         f'  constant AMY1_LOAD_AW    : natural := {LOAD_AW};',
         f'  constant AMY1_LOAD_WORDS : natural := {total};', '']
    for name, aw, base, fields in lm:
        L.append(f'  -- unit {name}: {1 << aw} words at {base}')
        if len(fields) > 1:
            L.append(f'  constant {name}_BASE : natural := {base};')
        for m, lsb in fields:
            mi, dw = mem_ident(m), len(m['data'])
            L.append(f'  --   {m["kind"][1:]} {m["name"]}: {1 << aw} x {dw}, bits {lsb + dw - 1}..{lsb}')
            L.append(f'  type {mi}_t is array (0 to {(1 << aw) - 1}) of std_logic_vector({dw - 1} downto 0);')
            L.append(f'  constant {mi.upper()}_BASE : natural := {base};')
            L.append(f'  constant {mi.upper()}_LSB  : natural := {lsb};')
        L.append('')
    L += ['end package;', '']
    open(path, 'w').write('\n'.join(L))


LOAD_PORTS = ['    load_we   : in  std_logic;                      -- write one image word',
              '    load_addr : in  std_logic_vector(10 downto 0);',
              '    load_data : in  std_logic_vector(31 downto 0);']


# Auxiliary port on the VOICE block RAM: amy1_top's note engine keeps its
# queue, instruments and voice state in the RAM's unused words (16..255) and
# uses the port on clocks with no step. The reference layout has no spare RAM
# and never accepts.
AUX_PORTS = [
    '    -- auxiliary port on the VOICE block RAM (words 16..255; the packed layout only)',
    "    aux_re    : in  std_logic := '0';                      -- read aux_raddr ...",
    "    aux_raddr : in  std_logic_vector(7 downto 0) := (others => '0');",
    '    aux_rack  : out std_logic;                             -- ... accepted: data next clock',
    '    aux_rdata : out std_logic_vector(35 downto 0);        -- valid the clock after aux_rack',
    "    aux_we    : in  std_logic := '0';                      -- write aux_wdata to aux_waddr ...",
    "    aux_waddr : in  std_logic_vector(7 downto 0) := (others => '0');",
    "    aux_wdata : in  std_logic_vector(35 downto 0) := (others => '0');",
    '    aux_wack  : out std_logic;                             -- ... done at this edge',
]
AUX_MAP = ['aux_re => aux_re', 'aux_raddr => aux_raddr', 'aux_rack => aux_rack', 'aux_rdata => aux_rdata',
           'aux_we => aux_we', 'aux_waddr => aux_waddr', 'aux_wdata => aux_wdata', 'aux_wack => aux_wack']


def write_mem(mems, path):
    ports = ['    clk     : in  std_logic;', '    step_en : in  std_logic;', ''] + LOAD_PORTS + [''] + AUX_PORTS + ['']
    body, decl = [], []
    for m in mems:
        mi, aw, dw = mem_ident(m), len(m['addr']), len(m['data'])
        ports.append(f'    {mi}_addr : in  std_logic_vector({aw - 1} downto 0);')
        if m['kind'] == '.RAM':
            ports.append(f'    {mi}_we : in  std_logic;')
            ports.append(f'    {mi}_wdata : in  std_logic_vector({dw - 1} downto 0);')
        ports.append(f'    {mi}_q : out std_logic_vector({dw - 1} downto 0);')
        decl.append(f'  signal {mi}_mem : {mi}_t;')
        body += [f'  -- {m["kind"][1:]} {m["name"]}: {1 << aw} x {dw}',
                 f'  {mi}_p: process (clk)', '  begin', '    if rising_edge(clk) then',
                 f"      if load_we = '1' then",
                 f'        if unsigned(load_addr({LOAD_AW - 1} downto {aw})) = {mi.upper()}_BASE / {1 << aw} then',
                 f'          {mi}_mem(to_integer(unsigned(load_addr({aw - 1} downto 0)))) <= load_data({mi.upper()}_LSB + {dw - 1} downto {mi.upper()}_LSB);',
                 '        end if;',
                 "      elsif step_en = '1' then"]
        if m['kind'] == '.RAM':
            body += [f"        if {mi}_we = '1' then",
                     f'          {mi}_mem(to_integer(unsigned({mi}_addr))) <= {mi}_wdata;',
                     '        end if;']
        body += [f'        {mi}_q <= {mi}_mem(to_integer(unsigned({mi}_addr)));',
                 '      end if;', '    end if;', '  end process;', '']
    ports[-1] = ports[-1][:-1]
    L = ['-------------------------------------------------------------------------------',
         '-- AMY1 memories: one block each, read synchronously at the step boundary',
         '-- (old data on a write), filled from the load image before the chip runs.',
         '-- Generated by vhdlgen.py. This is the reference layout; a packed layout must',
         '-- give the same data in the same step.',
         '-------------------------------------------------------------------------------',
         'library ieee;', 'use ieee.std_logic_1164.all;', 'use ieee.numeric_std.all;',
         'use work.amy1_mem_pkg.all;', '', 'entity amy1_mem is', '  port (', *ports, '  );',
         'end entity;', '', 'architecture rtl of amy1_mem is', *decl, 'begin', '',
         "  aux_rack  <= '0';", "  aux_wack  <= '0';", "  aux_rdata <= (others => '0');", '', *body,
         'end architecture;', '']
    open(path, 'w').write('\n'.join(L))


# PRB repair. Each sample one noise generator (address bit 0) runs through Noise RAM rows 0..31
# (address bits 5..1). Rows 0-14 hold three 15-bit shift registers (A, B, C in the three bits);
# the core shifts them one row per pass and XORs rows 0, 3, 8 and 14 into its feedback, but it
# writes that feedback to row 16 and rewrites row 0 with the arithmetic path, so the registers
# never get it. Here row 0 is written instead with the XOR of rows 0, 3, 8, 14 as written in the
# same generator's previous pass: three maximal-length (32767) LFSRs, and the core's own feedback
# (which steps the UD counter) is then exactly the bit that enters. Off while the host loads the
# RAM (NZINIT), and for the first pass after it.
NOISE_FIX_DECL = [
    '  signal noise_wcore : std_logic_vector(2 downto 0);',
    '  type nf_t is array (0 to 1) of std_logic_vector(2 downto 0);',
    "  signal nf_acc, nf_fb : nf_t := (others => (others => '0'));",
    "  signal nf_ok : std_logic_vector(1 downto 0) := \"00\";",
    "  signal nf_wl : std_logic := '0';                   -- noise_we in the previous step",
]
NOISE_FIX_BODY = [
    '  -- Noise generator PRB repair (NOISE_FIX)',
    '  nf_p: process (noise_addr, noise_we, noise_wcore, noise_init, nf_ok, nf_fb)',
    '    variable g : integer range 0 to 1;',
    '  begin',
    "    g := 0; if noise_addr(0) = '1' then g := 1; end if;",
    '    noise_wdata <= noise_wcore;',
    "    if NOISE_FIX and noise_init = '0' and noise_addr(5 downto 1) = \"00000\" and nf_ok(g) = '1' then",
    '      noise_wdata <= nf_fb(g);',
    '    end if;',
    '  end process;',
    '',
    '  nf_r: process (clk)',
    '    variable g : integer range 0 to 1;',
    '  begin',
    '    if rising_edge(clk) then',
    "      if step_en = '1' then",
    "        g := 0; if noise_addr(0) = '1' then g := 1; end if;",
    '        nf_wl <= noise_we;',
    "        if noise_init = '1' then",
    "          nf_ok <= \"00\";",
    "        elsif noise_we = '1' and nf_wl = '0' then        -- first step of a write",
    '          case to_integer(unsigned(noise_addr(5 downto 1))) is',
    '            when 0      => nf_acc(g) <= noise_wdata;',
    '            when 3 | 8  => nf_acc(g) <= nf_acc(g) xor noise_wcore;',
    "            when 14     => nf_fb(g) <= nf_acc(g) xor noise_wcore; nf_ok(g) <= '1';",
    '            when others => null;',
    '          end case;',
    '        end if;',
    '      end if;',
    '    end if;',
    '  end process;',
    '',
]


def write_chip(mems, path):
    """amy1 = amy1_core + amy1_mem: the chip's pins plus the memory load port."""
    pins = [l.split(':')[0].strip() for l in CORE_PORTS.splitlines() if ':' in l and not l.strip().startswith('--')]
    pins.remove('noise_init')
    sigs, cmap = ['  signal noise_init : std_logic;'], ['noise_init => noise_init']
    mmap = ['clk => clk', 'step_en => step_en', 'load_we => load_we', 'load_addr => load_addr',
            'load_data => load_data'] + AUX_MAP
    for m in mems:
        mi, aw, dw = mem_ident(m), len(m['addr']), len(m['data'])
        names = [(f'{mi}_addr', aw)] + ([(f'{mi}_we', 0), (f'{mi}_wdata', dw)] if m['kind'] == '.RAM' else []) + [(f'{mi}_q', dw)]
        for n, w in names:
            sigs.append(f'  signal {n} : ' + ('std_logic;' if w == 0 else f'std_logic_vector({w - 1} downto 0);'))
            if n == 'noise_wdata':          # the PRB repair sits between the core and the RAM
                cmap.append('noise_wdata => noise_wcore'); mmap.append('noise_wdata => noise_wdata')
            else:
                cmap.append(f'{n} => {n}'); mmap.append(f'{n} => {n}')
    ports = CORE_PORTS.replace(
        '    noise_init   : out std_logic;                      -- NZINIT: the host is loading the Noise RAM\n', '') + \
        '\n    -- memory load port (fill all memories before releasing reset)\n' + \
        '\n'.join(LOAD_PORTS) + '\n' + '\n'.join(AUX_PORTS)
    ports = ports[:ports.rfind(';')] + ports[ports.rfind(';') + 1:]
    L = ['-------------------------------------------------------------------------------',
         '-- AMY1: the core with its memories. Generated by vhdlgen.py.',
         '-------------------------------------------------------------------------------',
         'library ieee;', 'use ieee.std_logic_1164.all;', 'use ieee.numeric_std.all;', '',
         'entity amy1 is',
         '  generic (',
         '    -- Repair the noise generators\' pseudo-random registers (see below). false = the',
         '    -- netlist as drawn, where A, B and C get no feedback and freeze within 15 updates.',
         '    NOISE_FIX : boolean := true',
         '  );',
         '  port (', ports, '  );', 'end entity;', '',
         'architecture rtl of amy1 is', *sigs, *NOISE_FIX_DECL, 'begin', '', *NOISE_FIX_BODY,
         '  core: entity work.amy1_core port map (',
         ',\n'.join(['    ' + f'{p} => {p}' for p in pins] + ['    ' + c for c in cmap]), '  );', '',
         '  mem: entity work.amy1_mem(packed) port map (     -- or (rtl): the reference layout',
         ',\n'.join('    ' + c for c in mmap), '  );', '', 'end architecture;', '']
    open(path, 'w').write('\n'.join(L))


if __name__ == '__main__':
    devs = json.load(open(sys.argv[1]))
    mems = json.load(open(sys.argv[2]))
    outdir = sys.argv[4]
    os.makedirs(outdir, exist_ok=True)
    nl = Netlist(devs, mems, sys.argv[3])
    cw = CoreWriter(nl)
    if os.environ.get('NOCUT') != '1':
        import stepcut
        sc = stepcut.StepCut(nl, {n: set(v) for n, v in SEQUENCE.items()}, PINS_IN, PINS_IO, {0})
        outs = ['INTRDY', 'OUTSTBNT1', 'LDSAMP', 'NZINIT'] + [f'SAMP{i}' for i in range(16)] + \
               [f'SAMP{i}L' for i in range(17)] + [f'DB{i}' for i in range(8)]
        cw.plan = sc.plan(outs, {p for p in PINS_IO if p.startswith('DB')})
        p = cw.plan
        print(f'loop cuts: {len(p.exact)} exact, {len(p.pad)} pad inputs, {len(p.latch)} latches, '
              f'{len(p.other)} other; {len(p.regs)} extra registers; {len(p.loops)} loops left')
    cw.write(os.path.join(outdir, 'amy1_core.vhd'))
    write_mem_pkg(mems, os.path.join(outdir, 'amy1_mem_pkg.vhd'))
    write_mem(mems, os.path.join(outdir, 'amy1_mem.vhd'))
    write_chip(mems, os.path.join(outdir, 'amy1.vhd'))
    print(f'memory image: {write_image(mems, outdir)} words (amy1_mem.bin, amy1_mem.hex)')
    print(f'{len(nl.gate_of)} gates, {len(nl.resolved)} dynamic nets in {len(nl.networks)} networks, '
          f'{len(cw.regs)} charge registers, {cw.nterms} path terms -> {outdir}')
