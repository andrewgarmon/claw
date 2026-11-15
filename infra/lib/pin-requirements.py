#!/usr/bin/env python3
"""Add --hash=sha256 pins to a broker's PYREQS file, from PyPI.

For each `name==version` line, every wheel pip could pick on a claw host gets a hash: pure-Python
wheels, and manylinux x86_64/aarch64 wheels for CPython 3.12-3.14 (or abi3). Comments are kept;
existing hashes are replaced. Run it on your laptop or here, never on the host as root:

    python3 infra/lib/pin-requirements.py infra/brokers/cal/requirements.txt

Then check the diff and run the broker's tests.
"""

import json
import re
import sys
import urllib.request

PYTHONS = {"cp312", "cp313", "cp314"}
LINE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9][A-Za-z0-9.!+_-]*)(\s+--hash=sha256:[0-9a-f]{64})*\s*$")


def wanted(filename):
    # name-version(-build)?-pytag-abitag-platform.whl
    parts = filename[:-4].split("-")
    py, abi, plat = parts[-3], parts[-2], parts[-1]
    if plat == "any":
        return py.startswith(("py3", "py2.py3")) or bool(set(py.split(".")) & PYTHONS)
    if "manylinux" not in plat or not ("x86_64" in plat or "aarch64" in plat):
        return False
    return bool(set(py.split(".")) & PYTHONS) or abi == "abi3"


def hashes(name, version):
    with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{version}/json", timeout=30) as r:
        files = json.load(r)["urls"]
    out = sorted({f["digests"]["sha256"] for f in files
                  if f["packagetype"] == "bdist_wheel" and not f.get("yanked") and wanted(f["filename"])})
    if not out:
        sys.exit(f"{name}=={version}: no wheel for Linux x86_64/aarch64 CPython 3.12-3.14 (wheels only)")
    return out


def main(path):
    lines = []
    for line in open(path):
        line = line.rstrip("\n")
        m = LINE.match(line)
        if not m:
            if line.strip() and not line.lstrip().startswith("#"):
                sys.exit(f"not a name==version line: {line}")
            lines.append(line)
            continue
        name, version = m.group(1), m.group(2)
        lines.append(f"{name}=={version} " + " ".join(f"--hash=sha256:{h}" for h in hashes(name, version)))
    open(path, "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
