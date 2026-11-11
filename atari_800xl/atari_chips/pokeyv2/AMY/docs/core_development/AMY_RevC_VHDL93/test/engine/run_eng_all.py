"""All songs x ensembles through tb_engine (in parallel), each compared with engmodel.
usage: run_eng_all.py workdir [hpv8]"""
import sys, os
from multiprocessing import Pool
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_eng
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'songs')
songs = ['CANTINA', 'ENTERTA', 'MINWALTZ', 'BENIHILL', 'BACHCOR', 'TULL']

def one(a):
    s, e, wd, hpv8 = a
    ok, got, exp = run_eng.run(os.path.join(D, s + '.MUS'), e, None, wd, 'm%s%d' % (s[:3], e), hpv8=hpv8)
    jumps = rises = 0
    for (r, x), (r2, x2) in zip(exp, exp[1:]):
        if r == 1 and r2 == 3 and x2 != 0:
            if x == 0: jumps += 1
            elif x < 0x80: rises += 1
    return ok, len(got), jumps, rises

if __name__ == '__main__':
    wd = sys.argv[1]; hpv8 = len(sys.argv) > 2 and sys.argv[2] == 'hpv8'
    jobs = [(s, e, wd, hpv8) for s in songs for e in range(6)]
    with Pool(min(8, os.cpu_count())) as p:
        res = p.map(one, jobs)
    print('runs %d, differing %d, writes %d; attack breakpoints: %d jumps, %d rising' % (
        len(res), sum(not r[0] for r in res), sum(r[1] for r in res), sum(r[2] for r in res), sum(r[3] for r in res)))
