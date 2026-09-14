#!/usr/bin/env python3
"""
Assegna la prossima cartella numerata dentro output/, senza sovrascrivere le
precedenti. Stampa su stdout il path della cartella creata.

    python3 organize_output.py <output_dir>
"""
import os
import re
import sys

DIR_RE = re.compile(r"^(\d{3,})$")


def next_index(out_dir):
    mx = 0
    if os.path.isdir(out_dir):
        for n in os.listdir(out_dir):
            m = DIR_RE.match(n)
            if m and os.path.isdir(os.path.join(out_dir, n)):
                mx = max(mx, int(m.group(1)))
    return mx + 1


def main():
    if len(sys.argv) < 2:
        print("uso: organize_output.py <output_dir>", file=sys.stderr)
        sys.exit(1)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    folder = os.path.join(out, f"{next_index(out):03d}")
    os.makedirs(folder, exist_ok=True)
    print(folder)


if __name__ == "__main__":
    main()
