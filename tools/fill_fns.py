#!/usr/bin/env python3
"""fill_fns.py: the functions `minc-dbg --disasm --all` leaves out, looked up by name.

  python tools/fill_fns.py <exe> <fns.txt> <out.txt> <source dir>...

The listing omits a function whose line info has no file; `--disasm <exe> <name>` still
finds it. Every function name defined under the source directories that the listing
lacks is asked for, and the header lines found are written to out.txt, to be appended
to fns.txt for ripmap.py. Generic functions are skipped: their instantiated names are
not in the source. Slow, one process per name; minutes for a few thousand.
"""
import re, os, glob, subprocess, sys

exe, fns_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
roots = sys.argv[4:]
tabled = set()
for l in open(fns_path, encoding='utf-8', errors='replace'):
    m = re.match(r'(\S+)\s', l)
    if m:
        tabled.add(m.group(1))
names = set()
for root in roots:
    for f in glob.glob(os.path.join(root, '**', '*.mc'), recursive=True):
        for l in open(f, encoding='utf-8', errors='replace'):
            m = re.match(r'(?:private\s+)?(?:@\w+\s+)?[A-Za-z_][\w<>*, \[\]]*?\s\**([A-Za-z_]\w*)\s*\(', l)
            if m and not l.lstrip().startswith(('//', 'if', 'for', 'while', 'return', 'switch', 'else')) \
                    and '<' not in l.split('(')[0].split()[-1]:
                names.add(m.group(1))
todo = sorted(n for n in names if n not in tabled)
print(len(names), 'names,', len(todo), 'not in the listing', file=sys.stderr)
found = 0
with open(out_path, 'w', encoding='utf-8') as out:
    for i, n in enumerate(todo):
        r = subprocess.run(['minc-dbg', '--disasm', exe, n], capture_output=True, text=True, errors='replace')
        head = (r.stdout.split('\n') or [''])[0]
        if re.match(r'\S+\s+\S+:\d+\s+0x[0-9a-f]+\.\.0x[0-9a-f]+', head):
            out.write(head + '\n')
            found += 1
        if i % 200 == 0:
            print(i, 'asked,', found, 'found', file=sys.stderr)
            out.flush()
print('found', found, file=sys.stderr)
