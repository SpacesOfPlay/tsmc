#!/usr/bin/env python3
"""ripmap.py: a ripsample histogram mapped to files, functions and the interpreter's cases.

  python tools/ripmap.py --fns fns.txt --loop vm_execute.asm --src src/vm.mc
                         [--top N] [--lines CASE] [--runs N] hist.txt [hist2.txt ...]

fns.txt   the header lines of `minc-dbg --disasm --all <exe>` (name, file:line, 0xlow..0xhigh)
loop.asm  `minc-dbg --disasm <exe> vm_execute`, instructions under `; vm.mc:LINE` tags
src       the vm.mc the binary was built from (its line numbers are the tags')
hist      `ripsample` output: `addr count` lines in decimal, `outside N`, a `#` header
--runs    how many runs the histograms cover: the ms column divides by it
--lines   the source lines of one case (or `all`), most sampled first

A sample inside vm_execute goes to the case whose code it is in: the disassembly is
walked in address order and a tag whose line lies inside vm_execute's own lines names
the case; a tag outside them is an inlined callee and keeps the case it is in. The code
before the first case is `loop head`, the code after the switch `loop tail`. Samples
outside the image are the thread in system code: waiting, mostly.
"""
import argparse, bisect, re, sys

ap = argparse.ArgumentParser()
ap.add_argument('--fns', required=True)
ap.add_argument('--loop', required=True)
ap.add_argument('--src', required=True)
ap.add_argument('--top', type=int, default=40)
ap.add_argument('--lines', default=None)
ap.add_argument('--runs', type=int, default=1)
ap.add_argument('hists', nargs='+')
a = ap.parse_args()

# --- functions
fns = []
for line in open(a.fns, encoding='utf-8', errors='replace'):
    m = re.match(r'(\S.*?)\s+(\S+?):(\d+)\s+0x([0-9a-f]+)\.\.0x([0-9a-f]+)', line)
    if m:
        fns.append((int(m.group(4), 16), int(m.group(5), 16), m.group(1), m.group(2)))
fns.sort()
fn_lo = [f[0] for f in fns]

def fn_of(addr):
    i = bisect.bisect_right(fn_lo, addr) - 1
    if i >= 0 and fns[i][0] <= addr < fns[i][1]:
        return fns[i][2], fns[i][3]
    return '<outside .text>', '<outside .text>'

# --- the loop's cases, from the source
src = open(a.src, encoding='utf-8').read().split('\n')
fn_start = next(i + 1 for i, s in enumerate(src) if s.startswith('private i32 vm_execute(VM* vm, i32 stop_fp) {'))
fn_end = next(i + 1 for i in range(fn_start, len(src)) if src[i] == '}')
cases = []   # (line, label)
for i in range(fn_start - 1, fn_end):
    m = re.match(r'\s*case ((?:OP_\w+(?:, )?)+):', src[i])
    if m:
        cases.append((i + 1, m.group(1).replace('OP_', '')))
    elif re.match(r'\s*default:', src[i]):
        cases.append((i + 1, 'default'))
# the code after the switch: the first `sp = vm.sp;` at the loop's own depth past the last case
for i in range(cases[-1][0], fn_end):
    if src[i] == '        sp = vm.sp;':
        cases.append((i + 1, 'loop tail'))
        break
case_lines = [c[0] for c in cases]

def case_of_line(line):
    if not (fn_start <= line <= fn_end):
        return None
    i = bisect.bisect_right(case_lines, line) - 1
    return cases[i][1] if i >= 0 else 'loop head'

# --- the loop's instructions: address -> (case, line)
insts = []
cur_line = 0
cur_case = 'loop head'
loop_lo = loop_hi = None
for line in open(a.loop, encoding='utf-8', errors='replace'):
    m = re.match(r'vm_execute\s+\S+\s+0x([0-9a-f]+)\.\.0x([0-9a-f]+)', line)
    if m:
        loop_lo, loop_hi = int(m.group(1), 16), int(m.group(2), 16)
        continue
    m = re.match(r'\s*; vm\.mc:(\d+)$', line)
    if m:
        cur_line = int(m.group(1))
        c = case_of_line(cur_line)
        if c is not None:
            cur_case = c
        continue
    m = re.match(r'\s*0x([0-9a-f]+)\s', line)
    if m:
        insts.append((int(m.group(1), 16), cur_case, cur_line))
insts.sort()
inst_addr = [x[0] for x in insts]

def inst_of(addr):
    i = bisect.bisect_right(inst_addr, addr) - 1
    return insts[i] if i >= 0 else (addr, 'loop head', 0)

# --- the samples
total = 0
outside = 0
by_fn = {}
by_file = {}
by_case = {}
by_case_line = {}
for path in a.hists:
    for line in open(path, encoding='utf-8'):
        if line.startswith('#') or not line.strip():
            continue
        k, n = line.split()
        n = int(n)
        total += n
        if k == 'outside':
            outside += n
            continue
        addr = int(k)
        f, file = fn_of(addr)
        by_fn[f] = by_fn.get(f, 0) + n
        by_file[file] = by_file.get(file, 0) + n
        if loop_lo is not None and loop_lo <= addr < loop_hi:
            _, c, ln = inst_of(addr)
            by_case[c] = by_case.get(c, 0) + n
            by_case_line[(c, ln)] = by_case_line.get((c, ln), 0) + n

in_image = total - outside
loop_total = sum(by_case.values())
# a sample is interval_us of the thread's time; the header says the interval
interval_us = 250
for path in a.hists:
    m = re.search(r'interval (\d+) us', open(path, encoding='utf-8').readline())
    if m:
        interval_us = int(m.group(1))
def ms(n):
    return n * interval_us / 1000.0 / a.runs

print(f'{total} samples over {a.runs} run(s), {interval_us} us each: {ms(total):.0f} ms a run, of it '
      f'{ms(outside):.0f} outside the image (system code, waiting), {ms(in_image):.0f} in it, '
      f'{ms(loop_total):.0f} in vm_execute ({100.0 * loop_total / max(in_image, 1):.1f}% of the image\'s)')
print()
print('files (share of the image\'s samples, ms a run):')
for f, n in sorted(by_file.items(), key=lambda x: -x[1])[:a.top]:
    print(f'  {100.0 * n / max(in_image, 1):5.1f}%  {ms(n):7.0f}  {f}')
print()
print('functions:')
for f, n in sorted(by_fn.items(), key=lambda x: -x[1])[:a.top]:
    print(f'  {100.0 * n / max(in_image, 1):5.1f}%  {ms(n):7.0f}  {f}')
print()
print('vm_execute by case (share of the loop, ms a run):')
for c, n in sorted(by_case.items(), key=lambda x: -x[1])[:a.top]:
    print(f'  {100.0 * n / max(loop_total, 1):5.1f}%  {ms(n):7.0f}  {c}')
if a.lines:
    print()
    print(f'lines of {a.lines} (share of the case, ms a run):')
    sel = [(k, n) for k, n in by_case_line.items() if a.lines == 'all' or k[0] == a.lines]
    case_n = sum(n for _, n in sel)
    for (c, ln), n in sorted(sel, key=lambda x: -x[1])[:a.top]:
        text = src[ln - 1].strip() if 0 < ln <= len(src) else ''
        tag = f'{c} ' if a.lines == 'all' else ''
        print(f'  {100.0 * n / max(case_n, 1):5.1f}%  {ms(n):7.1f}  {tag}vm.mc:{ln}  {text[:90]}')
