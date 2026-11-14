"""arrangement events -> the player's byte stream, with back-references.
  $00-$3F  wait n+1 frames            $40+v  off v
  $48+v    on v, note, level          $50+v  vibrato v, depth
  $58+v    instrument v, inst         $60 lo hi n   play n bytes at lo/hi, then go on (no nesting)
  $61      end: back to the start
  $68+v    on v, note, level, keeping W2 (the harmonics) from the last note on
Back-references only ever cover whole events (the player returns between events)."""
import collections

def tokens(ev, length):
    """events -> list of byte tuples (one per event or wait)"""
    out = []
    by = collections.defaultdict(list)
    for e in ev: by[e[0]].append(e)
    t = 0
    frames = sorted(f for f in by if f < length)
    for f in frames:
        gap = f - t
        while gap > 0:
            n = min(gap, 64); out.append((n - 1,)); gap -= n
        for e in by[f]:
            k, v = e[1], e[2]
            if k == 'off': out.append((0x40 + v,))
            elif k == 'on': out.append((0x68 + v if len(e) > 6 else 0x48 + v, e[3], e[4]))
            elif k == 'vib': out.append((0x50 + v, e[3]))
            elif k == 'inst': out.append((0x58 + v, e[3]))
        t = f
    gap = length - t
    while gap > 0:
        n = min(gap, 64); out.append((n - 1,)); gap -= n
    return out

def compress(tok, base, min_bytes=8):
    """greedy: the longest earlier run of tokens (stored raw) that matches what comes next
    -> a $60 reference.  base: the address the stream is assembled at."""
    raw_at = []                 # for each token stored raw: (index in tok, byte offset in output)
    out = bytearray(); i = 0
    index = collections.defaultdict(list)       # 3-token key -> positions in raw_at
    n_ref = 0; refs = []
    while i < len(tok):
        best = (0, 0, 0)        # bytes, raw_at position, tokens
        key = tuple(tok[i:i + 3])
        if len(key) == 3:
            for p in index.get(key, ()):
                ti0, off0 = raw_at[p]
                L = 0; nb = 0
                # tokens stored raw contiguously from raw_at[p]
                while i + L < len(tok) and p + L < len(raw_at):
                    ti, off = raw_at[p + L]
                    if off != off0 + nb or tok[ti] != tok[i + L]: break
                    nb += len(tok[i + L]); L += 1
                    if nb >= 250: break
                if nb > best[0]: best = (nb, p, L)
        if best[0] >= min_bytes:
            nb, p, L = best
            off = raw_at[p][1]; a = base + off
            refs.append(len(out))
            out += bytes([0x60, a & 255, a >> 8, nb])
            i += L; n_ref += 1
            continue
        raw_at.append((i, len(out)))
        if i + 2 < len(tok):
            index[tuple(tok[i:i + 3])].append(len(raw_at) - 1)
        out += bytes(tok[i]); i += 1
    out.append(0x61)
    compress.refs = refs
    return bytes(out), n_ref

def asm(data, base, label, refs):
    """ca65 lines for a stream compressed at base, references as label + offset"""
    L = []; i = 0; row = []
    rs = set(refs)
    def flush():
        if row: L.append('        .byte ' + ','.join(row)); row.clear()
    while i < len(data):
        if i in rs:
            flush()
            off = (data[i + 1] | data[i + 2] << 8) - base
            L.append('        .byte $60\n        .word %s+%d\n        .byte %d' % (label, off, data[i + 3]))
            i += 4; continue
        row.append('$%02X' % data[i]); i += 1
        if len(row) == 24: flush()
    flush()
    return L

def decode(data, base):
    """the player's view: the token stream back (to check compress)"""
    res = []; p = 0; ret = None; left = 0
    def ln(b): return 1 if b < 0x48 else 3 if b < 0x50 else 2 if b < 0x60 else 4 if b == 0x60 else 1 if b == 0x61 else 3
    while True:
        b = data[p]
        if b == 0x61 and ret is None: break
        if b == 0x60:
            ret = p + 4; left = data[p + 3]; p = (data[p + 1] | data[p + 2] << 8) - base; continue
        n = ln(b); res.append(tuple(data[p:p + n])); p += n
        if ret is not None:
            left -= n
            if left == 0: p = ret; ret = None
    return res
