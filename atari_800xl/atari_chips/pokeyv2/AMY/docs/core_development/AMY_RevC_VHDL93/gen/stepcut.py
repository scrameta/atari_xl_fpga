"""Step analysis of the AMY1 netlist: which reads can use last step's value.

The step model evaluates the whole chip combinationally in every step. Because the chip is a
two-phase design, that logic is full of structural loops (a latch on CLK feeds logic that
feeds a latch on CLKN that feeds back ...) although a loop is never closed within one step.
FPGA tools need loop-free logic, so we cut every switch read that provably does not need the
current step's value:

  on(g)   steps in which switch gate g can be 1          (3-valued periodic simulation)
  chg(x)  steps in which x can differ from the previous step  (least fixpoint)

A source term "g and b" of a network can read b_reg (b at the end of the previous step)
instead of b when on(g) and chg(b) are disjoint: whenever the switch can conduct, b has not
changed in this step. That is exact, not an approximation.

chg rules: clocks change where the sequence changes; pins and memory outputs can change in
every step; a gate output changes only when an input does; a switch network can change in a
step only if some source in it can conduct in that step AND one of its inputs changed (with
nothing conducting it holds; with unchanged inputs it re-evaluates to the same value).
"""
from collections import defaultdict

X = 2                         # unknown, in the 3-valued simulation
ALL = frozenset(range(6))


def v_not(a):
    return X if a == X else 1 - a


def v_and(vals):
    r = 1
    for v in vals:
        if v == 0:
            return 0
        if v == X:
            r = X
    return r


def v_or(vals):
    r = 0
    for v in vals:
        if v == 1:
            return 1
        if v == X:
            r = X
    return r


def v_gate(t, vals):
    if t == '.INV':
        return v_not(vals[0])
    r = v_and(vals) if t in ('.AND', '.NAND') else v_or(vals)
    return v_not(r) if t in ('.NAND', '.NOR') else r


class StepCut:
    def __init__(self, nl, clocks, pins_in, pins_io, pin_steps=ALL):
        self.nl = nl
        self.pin_steps = frozenset(pin_steps)    # steps in which the host may change a pin
        self.clocks = clocks                     # name -> steps in which it is 1
        self.pins = set(pins_in) | set(pins_io)
        # terms per resolved net: (gate or None, value) where value is a signal name,
        # '0'/'1', or a tuple for memory/pin pseudo-signals
        self.terms = defaultdict(list)
        for n in nl.resolved:
            for g in ([nl.gate_of[n]] if n in nl.gate_of else []) + nl.extra_gates.get(n, []):
                self.terms[n].append((None, ('expr', g[0], tuple(g[1]))))
            if n in nl.rom_bit:
                self.terms[n].append((None, ('mem', nl.rom_bit[n][0])))
            for kind, g in nl.pull.get(n, []):
                if kind == 'PULL':
                    self.terms[n].append((None, '1'))
                else:
                    self.terms[n].append((g, '1' if kind == 'VCC' else '0'))
            for mname, b in nl.ram_bit.get(n, []):
                self.terms[n].append((('rd', mname), ('mem', mname)))
            if n in pins_io:
                self.terms[n].append((('pin',), ('pin',)))
            for g, b in nl.outer.get(n, []):
                self.terms[n].append((g, b))
        self.ram_rd = {m['name']: (m['re'], m['we']) for m in nl.mems if m['kind'] == '.RAM'}
        self.net_of = {}
        for i, (nets, sw) in enumerate(nl.networks):
            for n in nets:
                self.net_of[n] = i
        self._simulate()
        self._changes()

    # ------------------------------------------------------------------ 3-valued simulation
    def _val(self, x, cur, s):
        if isinstance(x, tuple):
            k = x[0]
            if k == 'expr':
                return v_gate(x[1], [self._val(i, cur, s) for i in x[2]])
            if k == 'rd':
                re, we = self.ram_rd[x[1]]
                return v_and([self._val(re, cur, s), v_not(self._val(we, cur, s))])
            return X                                 # memory data, pins
        if x in ('1', 'VCC', '.VCC'):
            return 1
        if x in ('0', 'GND', '.GND'):
            return 0
        if x in self.clocks:
            return 1 if s in self.clocks[x] else 0
        return cur.get(x, X)

    def _net_values(self, nets, sw, cur, prev, s):
        """The step model's rule for one network, in 3-valued logic."""
        z, o = {}, {}
        for n in nets:
            zt, ot = [], []
            for g, v in self.terms[n]:
                gv = 1 if g is None else self._val(g, cur, s)
                vv = self._val(v, cur, s)
                zt.append(v_and([gv, v_not(vv)])); ot.append(v_and([gv, vv]))
            z[n], o[n] = v_or(zt), v_or(ot)
        rip = self.nl.ripple(nets, sw)
        if rip is not None:
            order, fwd = rip
            back = defaultdict(list)
            for g, a, b in fwd:
                back[b].append((g, a))
            for n in order:
                for g, a in back[n]:
                    gv = 1 if g is None else self._val(g, cur, s)
                    z[n] = v_or([z[n], v_and([gv, z[a]])]); o[n] = v_or([o[n], v_and([gv, o[a]])])
        else:
            adj = defaultdict(list)
            for g, a, b in sw:
                adj[a].append((g, b)); adj[b].append((g, a))
            for _ in range(self.nl.depth(nets, sw)):
                z2, o2 = {}, {}
                for n in nets:
                    zs, os_ = [z[n]], [o[n]]
                    for g, m in adj[n]:
                        gv = 1 if g is None else self._val(g, cur, s)
                        zs.append(v_and([gv, z[m]])); os_.append(v_and([gv, o[m]]))
                    z2[n], o2[n] = v_or(zs), v_or(os_)
                z, o = z2, o2
        res, drive = {}, False
        for n in nets:
            if z[n] == 1:
                res[n] = 0
            elif z[n] == 0 and o[n] == 1:
                res[n] = 1
            elif z[n] == 0 and o[n] == 0:
                res[n] = prev.get(n, X)
            else:
                res[n] = X
        return res

    def _simulate(self):
        nl = self.nl
        gates = [(n, t, ins) for n, (t, ins) in nl.gate_of.items() if n not in set(nl.resolved)]
        vals = [dict() for _ in range(6)]
        for cycle in range(40):
            changed = False
            for s in range(6):
                prev, cur = vals[(s - 1) % 6], {}
                for _ in range(200):           # combinational fixpoint within the step
                    before = dict(cur)
                    for n, t, ins in gates:
                        cur[n] = v_gate(t, [self._val(i, cur, s) for i in ins])
                    for nets, sw in nl.networks:
                        cur.update(self._net_values(nets, sw, cur, prev, s))
                    if cur == before:
                        break
                if cur != vals[s]:
                    vals[s] = cur; changed = True
            if not changed:
                break
        self.vals = vals
        self.on = {}

    def on_steps(self, g):
        if g is None:
            return ALL
        if g not in self.on:
            self.on[g] = frozenset(s for s in range(6) if self._val(g, self.vals[s], s) != 0)
        return self.on[g]

    # ------------------------------------------------------------------ change sets
    def _changes(self):
        nl = self.nl
        clk_chg = {c: frozenset(s for s in range(6) if (s in st) != (((s - 1) % 6) in st))
                   for c, st in self.clocks.items()}
        chg = defaultdict(frozenset)
        resolved = set(nl.resolved)

        def of(x):
            if isinstance(x, tuple):
                if x[0] == 'expr':
                    return frozenset().union(*[of(i) for i in x[2]])
                if x[0] == 'rd':
                    re, we = self.ram_rd[x[1]]
                    return of(re) | of(we)
                if x[0] == 'mem':
                    return mem_chg[x[1]]
                return self.pin_steps                # pins
            if x in ('0', '1', 'VCC', 'GND', '.VCC', '.GND'):
                return frozenset()
            if x in clk_chg:
                return clk_chg[x]
            if x in self.pins:
                return self.pin_steps
            return chg[x]

        # Per network and step: the groups of nets joined by switches that can conduct in that
        # step, and whether any source in the group can conduct. A net can only change in a
        # step if its group has a conducting source and one of the group's inputs changed.
        groups = []                      # per network: per step: list of (nets, conducting, terms, switches)
        for nets, sw in nl.networks:
            per_step = []
            for st in range(6):
                par = {n: n for n in nets}

                def root(x):
                    while par[x] != x:
                        par[x] = par[par[x]]; x = par[x]
                    return x
                live = [(g, a, b) for g, a, b in sw if g is None or self._val(g, self.vals[st], st) != 0]
                for g, a, b in live:
                    par[root(a)] = root(b)
                grp = defaultdict(list)
                for n in nets:
                    grp[root(n)].append(n)
                out = []
                for members in grp.values():
                    mset = set(members)
                    terms = [(g, v) for n in members for g, v in self.terms[n]]
                    conducting = any(g is None or self._val(g, self.vals[st], st) != 0 for g, v in terms)
                    out.append((members, conducting, terms, [g for g, a, b in live if a in mset]))
                per_step.append(out)
            groups.append(per_step)
        gates = [(n, ins) for n, (t, ins) in nl.gate_of.items() if n not in resolved]
        shift = lambda st, k: frozenset((x + k) % 6 for x in st)
        mem_chg = {m['name']: frozenset() for m in nl.mems}
        for _ in range(500):
            changed = False
            # q(s+1) = mem[addr(s)]: changes after an address change, or two steps after a write
            for m in nl.mems:
                c = shift(frozenset().union(*[of(a) for a in m['addr']]), 1)
                if m['kind'] == '.RAM':
                    c |= shift(self.on_steps(m['we']), 2)
                if c != mem_chg[m['name']]:
                    mem_chg[m['name']] = c; changed = True
            for n, ins in gates:
                c = frozenset().union(*[of(i) for i in ins])
                if c != chg[n]:
                    chg[n] = c; changed = True
            for per_step in groups:
                new = defaultdict(set)
                for st, out in enumerate(per_step):
                    for members, conducting, terms, live in out:
                        if not conducting:
                            continue
                        inp = set()
                        for g, v in terms:
                            if g is not None:
                                inp |= of(g)
                            inp |= of(v) & self.on_steps(g)   # v only matters while g conducts
                        for g in live:
                            if g is not None:
                                inp |= of(g)
                        if st in inp:
                            for n in members:
                                new[n].add(st)
                for members, conducting, terms, live in per_step[0]:
                    for n in members:
                        c = frozenset(new[n])
                        if c != chg[n]:
                            chg[n] = c; changed = True
            if not changed:
                break
        self.chg = chg
        self.of = of

    # ------------------------------------------------------------------ loop cutting
    def _reads(self):
        """Every read in the design: (consumer, source signal, steps in which it matters).

        consumer is a gate output name, or ('N', i, n, g, b) for the source term g & b of net n
        in network i. Sources of reads that can never be cut (switch gates, memory ports) are
        still listed so that need() is complete."""
        nl, res = self.nl, set(self.nl.resolved)
        reads = []
        for y, (t, ins) in nl.gate_of.items():
            if y not in res:
                for x in ins:
                    reads.append((y, x, None))           # None: steps where y is needed
        for i, (nets, sw) in enumerate(nl.networks):
            for n in nets:
                for g, v in self.terms[n]:
                    for x in self._names(g):
                        reads.append((('N', i), x, ALL))
                    if isinstance(v, str):
                        reads.append((('N', i, n, g, v), v, self.on_steps(g)))
                    else:
                        for x in self._names(v):
                            reads.append((('N', i), x, ALL))
            for g, a, b in sw:
                for x in self._names(g):
                    reads.append((('N', i), x, ALL))
        for m in nl.mems:
            for x in m['addr'] + m['data'] + ([m['re'], m['we']] if m['re'] else []):
                reads.append((('MEM',), x, ALL))
        return reads

    def _names(self, x):
        if x is None:
            return []
        if isinstance(x, tuple):
            if x[0] == 'expr':
                return list(x[2])
            if x[0] == 'rd':
                return list(self.ram_rd[x[1]])
            return []
        return [x]

    def plan(self, outputs, pads):
        """Make the logic loop-free. Returns a Plan with

          exact   reads that use last step's value and provably see the same value
          latch   cross-coupled pairs (a, b): a reads b_pre = b evaluated with a_reg, which
                  is the latch's fixed point from its previous state (exact)
          pad     pad input buffers read the pad's previous value (one step, about 40 ns, of
                  input delay; breaks the pad -> input buffer -> bus -> output driver loop,
                  which is never closed because DINB and DOUTN are exclusive)
          other   the few remaining reads cut the same way (checked by simulation)
          regs    gate outputs that need a register for these reads
          loops   anything left (should be empty)
        """
        nl, res = self.nl, set(self.nl.resolved)
        gates = set(y for y in nl.gate_of if y not in res)
        reads = self._reads()
        shift = lambda st, k: frozenset((x + k) % 6 for x in st)
        net_i = {n: i for i, (nets, sw) in enumerate(nl.networks) for n in nets}

        def nid(x):
            return x if x in gates else ('N', net_i[x]) if x in net_i else None

        def cnode(c):
            return c if isinstance(c, str) else ('N', c[1]) if c[0] == 'N' else None

        plan = Plan()

        def need():
            """Steps in which each gate output must hold its true value."""
            M = defaultdict(frozenset)
            for o in list(outputs) + [a for a, b in plan.latch]:
                if o in gates:
                    M[o] = ALL
            for _ in range(1000):
                changed = False
                for c, x, R in reads:
                    if x not in gates:
                        continue
                    r = M[c] if R is None else R
                    if (c, x) in plan.cut:
                        r = r | shift(r, -1)             # x_reg read in s is x of step s-1
                    if not r <= M[x]:
                        M[x] = M[x] | r; changed = True
                if not changed:
                    return M
            raise RuntimeError('need() did not converge')

        def loops():
            g = defaultdict(set)
            for c, x, R in reads:
                if (c, x) in plan.cut or (c, x) in plan.pre:
                    continue
                a, b = cnode(c), nid(x)
                if a is not None and b is not None:
                    g[a].add(b)
            return _sccs(g)

        def inside(comps):
            where = {}
            for k, comp in enumerate(comps):
                for v in comp:
                    where[v] = k
            return lambda c, x: cnode(c) is not None and where.get(cnode(c), -1) == where.get(nid(x), -2)

        # 1. exact cuts inside loops: resolved nets first (their _reg exists), then gate outputs
        for free_only in (True, False):
            same = inside(loops())
            M = need()
            for c, x, R in reads:
                if (c, x) in plan.cut or not same(c, x):
                    continue
                if isinstance(c, tuple) and len(c) == 2:
                    continue                             # switch gates, gate-driven terms
                if free_only and x in gates:
                    continue
                if not (self.chg[x] & (M[c] if R is None else R)):
                    plan.exact.add((c, x))
            while True:                                  # drop cuts invalidated by new needs
                M = need()
                bad = {(c, x) for c, x, R in reads if (c, x) in plan.exact
                       and self.chg[x] & (M[c] if R is None else R)}
                if not bad:
                    break
                plan.exact -= bad

        # 2. pad input buffers
        same = inside(loops())
        for c, x, R in reads:
            if x in pads and isinstance(c, tuple) and len(c) == 2 and same(c, x) and c != nid(x):
                plan.pad.add((c, x))

        # 3. cross-coupled pairs
        for comp in loops():
            if len(comp) == 2 and any(isinstance(v, str) for v in comp):
                b = sorted(v for v in comp if isinstance(v, str))[0]
                a = [v for v in comp if v != b][0]
                plan.latch.append((a, b))
                for c, x, R in reads:
                    if x == b and cnode(c) == a:
                        plan.pre[(c, x)] = a

        # 4. anything else (static register hold paths, bus read-back): cut source-term
        #    reads inside the loop, then switch-gate reads, then gate inputs
        for kind in (5, 2, 'gate'):
            same = inside(loops())
            for c, x, R in reads:
                k = 'gate' if isinstance(c, str) else len(c)
                if k == kind and same(c, x) and (c, x) not in plan.pre:
                    plan.other.add((c, x))
        plan.loops = loops()
        plan.need = need()
        plan.reads = reads
        plan.regs = sorted(set(x for c, x in plan.cut if x in gates) |
                           set(a for a, b in plan.latch if a in gates))
        return plan


class Plan:
    def __init__(self):
        self.exact, self.pad, self.other = set(), set(), set()
        self.latch, self.pre = [], {}
        self.regs, self.loops = [], []

    @property
    def cut(self):
        return self.exact | self.pad | self.other


def _sccs(g):
    import sys
    sys.setrecursionlimit(1000000)
    index, low, stack, on, comps, cnt = {}, {}, [], set(), [], [0]

    def visit(v):
        index[v] = low[v] = cnt[0]; cnt[0] += 1; stack.append(v); on.add(v)
        for w in g.get(v, ()):
            if w not in index:
                visit(w); low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop(); on.discard(w); comp.append(w)
                if w == v:
                    break
            if len(comp) > 1 or v in g.get(v, ()):
                comps.append(comp)
    for v in list(g):
        if v not in index:
            visit(v)
    return comps
