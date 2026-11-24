#!/usr/bin/env python3
"""Mark SUSFS credential helpers maybe-unused for BakaSU's Kconfig.

BakaSU's Kconfig does not expose CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER.
SUSFS 2.4.0 nevertheless ships the priority-filter credential helpers, while
sus_path UID-filter code also calls susfs_restore_creds(). Keep both helpers
available to real callers and silence -Wunused-function when priority filtering
is compiled out. This is deliberately an attribute fix, not a feature stub.
"""
from pathlib import Path
import sys

path = Path(sys.argv[1])
src = path.read_text()
original = src
replacements = {
    "static struct cred *susfs_switch_to_ksu_domain(void) {":
        "static struct cred * __maybe_unused susfs_switch_to_ksu_domain(void) {",
    "static void susfs_restore_creds(struct cred *orig_cred) {":
        "static void __maybe_unused susfs_restore_creds(struct cred *orig_cred) {",
}
for old, new in replacements.items():
    if new not in src and old in src:
        src = src.replace(old, new, 1)
if src == original:
    if all(new in src for new in replacements.values()):
        print("[+] SUSFS credential helpers already marked __maybe_unused")
        raise SystemExit(0)
    missing = [old for old in replacements if old not in src]
    raise SystemExit("[!] unexpected SUSFS 2.4.0 helper signatures: " + ", ".join(missing))
if not all(new in src for new in replacements.values()):
    raise SystemExit("[!] failed to mark both SUSFS credential helpers")
path.write_text(src)
print("[+] marked SUSFS credential helpers __maybe_unused")
