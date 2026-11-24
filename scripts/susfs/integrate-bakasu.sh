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

# Add the NoMount xattr guard after SUSFS has finished modifying the filesystem
# sources. Keep this as a semantic insertion instead of a line-numbered patch:
# upstream xattr.c context/count changes must not break the whole build.
python3 - "$KROOT/fs/xattr.c" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text()
signature = "vfs_getxattr(struct user_namespace *mnt_userns"
start = source.find(signature)
if start < 0 or source.find(signature, start + 1) >= 0:
    raise SystemExit("NoMount: vfs_getxattr() is missing or ambiguous")

end_marker = "EXPORT_SYMBOL_GPL(vfs_getxattr);"
end = source.find(end_marker, start)
if end < 0:
    raise SystemExit("NoMount: vfs_getxattr() end marker not found")
body = source[start:end]
call = "nm_inode_hidden_from_caller(inode)"
if call in body:
    print("[=] NoMount xattr guard already present")
else:
    anchor = "error = security_inode_getxattr(dentry, name);"
    if body.count(anchor) != 1:
        print(body, file=sys.stderr)
        raise SystemExit("NoMount: unique security_inode_getxattr() call not found in vfs_getxattr()")
    hook = """#ifdef CONFIG_NOMOUNT
	{ extern bool nm_inode_hidden_from_caller(const struct inode *);
	  if (nm_inode_hidden_from_caller(inode))
		  return -ENOENT; }
#endif

	"""
    pos = start + body.index(anchor)
    source = source[:pos] + hook + source[pos:]
    path.write_text(source)
    print("[+] NoMount xattr guard inserted in vfs_getxattr()")
PY
grep -q 'nm_inode_hidden_from_caller(inode)' "$KROOT/fs/xattr.c" || {
  echo "[!] NoMount xattr guard missing after SUSFS integration"; exit 1;
}

# Place the NoMount maps hook inside show_map_vma(), after the inode metadata
# overrides (including SUSFS kstat) and before pgoff is consumed.
python3 - "$KROOT/fs/proc/task_mmu.c" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text()

# task_mmu.c does not include the private NoMount engine header. Declare the
# narrow cross-directory interface here, guarded by CONFIG_NOMOUNT.
decl = """#ifdef CONFIG_NOMOUNT
void vfs_map_meta_override(const struct inode *inode, dev_t *dev,
                           unsigned long *ino);
#endif
"""
include_anchor = '#include "internal.h"'
if decl.strip() not in source:
    if source.count(include_anchor) != 1:
        raise SystemExit("NoMount: unique task_mmu.c internal.h include not found")
    source = source.replace(include_anchor, include_anchor + "\n\n" + decl, 1)

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
    # show_map_vma() has another pgoff assignment in the SUSFS open-redirect
    # fast path. Anchor after the normal-path SUSFS kstat override instead.
    anchor = "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT"
    if body.count(anchor) != 1:
        excerpt = body[:5000]
        print(excerpt, file=sys.stderr)
        raise SystemExit("NoMount: unique SUSFS kstat end marker not found inside show_map_vma()")
    pos = brace + body.index(anchor) + len(anchor)
    source = source[:pos] + "\n" + hook + source[pos:]
    path.write_text(source)
    print("[+] NoMount maps metadata hook placed after SUSFS kstat override")
PY
grep -q 'vfs_map_meta_override(inode, &dev, &ino)' "$KROOT/fs/proc/task_mmu.c" || {
  echo "[!] NoMount maps metadata hook missing after SUSFS integration"; exit 1;
}
python3 scripts/susfs/fix-priority-uid-helpers.py "$KROOT/fs/susfs.c"
