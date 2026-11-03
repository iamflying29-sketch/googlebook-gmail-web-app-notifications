"""Copies every shared library the given ELF files need (their whole dependency tree, as ldd resolves
it in this VM) into one folder. Usage: collect.py <dest-lib-dir> <elf> [<elf> ...]"""
import os
import shutil
import subprocess
import sys

dest = sys.argv[1]
todo = list(sys.argv[2:])
seen = set()
copied = 0
while todo:
    f = todo.pop()
    if f in seen:
        continue
    seen.add(f)
    out = subprocess.run(["ldd", f], capture_output=True, text=True, timeout=60).stdout
    for line in out.splitlines():
        line = line.strip()
        if "not found" in line:
            sys.exit("missing library for %s: %s" % (f, line))
        path = None
        if "=>" in line:
            path = line.split("=>", 1)[1].split()[0]
        elif line.startswith("/"):
            path = line.split()[0]
        if not path or not os.path.isfile(path):
            continue
        target = os.path.join(dest, os.path.basename(path))
        if not os.path.exists(target):
            shutil.copy(os.path.realpath(path), target)
            copied += 1
        todo.append(path)
    # The extra libraries named on the command line are copied themselves too.
    if f.startswith("/usr/lib") or f.startswith("/lib"):
        target = os.path.join(dest, os.path.basename(f))
        if not os.path.exists(target):
            shutil.copy(os.path.realpath(f), target)
            copied += 1
print("collect: %d libraries in %s" % (copied, dest))
