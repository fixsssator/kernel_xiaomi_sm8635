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

# Defer the NoMount maps hook until after SUSFS adds its kstat override.
python3 - "$KROOT/fs/proc/task_mmu.c" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text()
marker = "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT"
hook = """#ifdef CONFIG_NOMOUNT
		{ extern void vfs_map_meta_override(const struct inode *,
							  dev_t *, unsigned long *);
		  vfs_map_meta_override(inode, &dev, &ino); }
#endif"""
if "vfs_map_meta_override(inode, &dev, &ino)" not in source:
    if source.count(marker) != 1:
        raise SystemExit("NoMount insertion point missing or ambiguous after SUSFS kstat hook")
    source = source.replace(marker, marker + "\n" + hook, 1)
path.write_text(source)
print("[+] NoMount maps metadata hook placed after SUSFS kstat override")
PY
grep -q 'vfs_map_meta_override(inode, &dev, &ino)' "$KROOT/fs/proc/task_mmu.c" || {
  echo "[!] NoMount maps metadata hook missing after SUSFS integration"; exit 1;
}
python3 scripts/susfs/fix-priority-uid-helpers.py "$KROOT/fs/susfs.c"
