#!/usr/bin/env bash
# BakaSU native SUSFS integration guard.
# BakaSU already implements the driver-side SUSFS command dispatcher, SELinux
# SID glue and susfs_init() lifecycle. Only the matching SUSFS kernel-side
# patch is applied; never graft the KSUN/SukiSU compatibility shims onto it.
set -euo pipefail

S4K_DIR="${1:?susfs4ksu dir}"
KROOT="${2:?kernel root}"
BAKASU_DIR="${3:?BakaSU checkout}"

require() {
  local file="$1" pattern="$2" label="$3"
  grep -qE "$pattern" "$file" || {
    echo "[!] BakaSU compatibility check failed: $label ($file)" >&2
    exit 1
  }
}

require "$BAKASU_DIR/kernel/Kconfig" 'config KSU_SUSFS([[:space:]]|$)' 'SUSFS hook choice'
require "$BAKASU_DIR/kernel/supercall/dispatch.c" 'int ksu_handle_susfs_cmd\(' 'SUSFS command dispatcher'
require "$BAKASU_DIR/kernel/selinux/selinux.c" 'bool susfs_is_current_ksu_domain\(' 'KSU SELinux-domain helper'
require "$BAKASU_DIR/kernel/selinux/selinux.c" 'u32 susfs_ksu_sid' 'KSU SID export'
require "$BAKASU_DIR/kernel/selinux/selinux.c" 'u32 susfs_priv_app_sid' 'priv_app SID export'
require "$BAKASU_DIR/kernel/core/init.c" 'susfs_init\(\)' 'SUSFS initialization'

echo "[+] BakaSU driver-side SUSFS API verified"

# BakaSU's dispatcher and userspace API require these exact SUSFS ABI entries.
# Validate the numeric IDs and both declarations/implementations instead of
# synthesizing command macros: an ABI-only shim can compile while remaining
# functionally incomplete.
require "$S4K_DIR/kernel_patches/include/linux/susfs_def.h" '#define CMD_SUSFS_SET_SUS_PATH_UID_FILTER[[:space:]]+0x55554([[:space:]]|$)' 'sus path UID-filter command ID'
require "$S4K_DIR/kernel_patches/include/linux/susfs_def.h" '#define CMD_SUSFS_SET_PRIORITY_UID_FILTER[[:space:]]+0x60030([[:space:]]|$)' 'priority UID-filter command ID'
for symbol in susfs_set_sus_path_uid_filter susfs_set_priority_uid_filter; do
  require "$S4K_DIR/kernel_patches/include/linux/susfs.h" "void[[:space:]]+$symbol[[:space:]]*\(" "$symbol header declaration"
  require "$S4K_DIR/kernel_patches/fs/susfs.c" "void[[:space:]]+$symbol[[:space:]]*\(" "$symbol implementation"
done

bash scripts/susfs/integrate-native.sh "$S4K_DIR" "$KROOT"

# Place the NoMount maps hook inside show_map_vma(), after the inode metadata
# overrides (including SUSFS kstat) and before pgoff is consumed.
python3 - "$KROOT/fs/proc/task_mmu.c" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text()
signature = "show_map_vma(struct seq_file *m, struct vm_area_struct *vma)"
hook = """#ifdef CONFIG_NOMOUNT
		vfs_map_meta_override(inode, &dev, &ino);
#endif
"""

start = source.find(signature)
if start < 0 or source.find(signature, start + 1) >= 0:
    raise SystemExit("NoMount: show_map_vma() is missing or ambiguous")

brace = source.find("{", start)
if brace < 0:
    raise SystemExit("NoMount: show_map_vma() opening brace not found")

depth = 0
end = -1
for i in range(brace, len(source)):
    if source[i] == "{":
        depth += 1
    elif source[i] == "}":
        depth -= 1
        if depth == 0:
            end = i
            break
if end < 0:
    raise SystemExit("NoMount: show_map_vma() closing brace not found")

body = source[brace:end]
call = "vfs_map_meta_override(inode, &dev, &ino)"
if call in body:
    print("[=] NoMount maps metadata hook already present")
else:
    anchor = "pgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;"
    if body.count(anchor) != 1:
        excerpt = body[:5000]
        print(excerpt, file=sys.stderr)
        raise SystemExit("NoMount: unique pgoff assignment not found inside show_map_vma()")
    pos = brace + body.index(anchor)
    # The SUSFS kstat block must precede this insertion point when SUSFS is enabled.
    kstat = "CONFIG_KSU_SUSFS_SUS_KSTAT"
    if kstat in body and body.index(kstat) > body.index(anchor):
        raise SystemExit("NoMount: SUSFS kstat override appears after the maps hook insertion point")
    source = source[:pos] + hook + source[pos:]
    path.write_text(source)
    print("[+] NoMount maps metadata hook placed inside show_map_vma() before pgoff")
PY
grep -q 'vfs_map_meta_override(inode, &dev, &ino)' "$KROOT/fs/proc/task_mmu.c" || {
  echo "[!] NoMount maps metadata hook missing after SUSFS integration"; exit 1;
}
python3 scripts/susfs/fix-priority-uid-helpers.py "$KROOT/fs/susfs.c"
