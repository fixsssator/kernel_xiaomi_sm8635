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

# BakaSU's userspace/kernel ABI has two commands newer than the pinned
# susfs4ksu v2.3.0 header. Their numeric IDs are defined by BakaSU's own
# userspace API (kernel/supercall/dispatch.c must use the same values).
# The corresponding handlers must exist in fs/susfs.c before we expose them.
for symbol in susfs_set_sus_path_uid_filter susfs_set_priority_uid_filter; do
  grep -qE "^[[:space:]]*void[[:space:]]+$symbol[[:space:]]*\\(" "$S4K_DIR/kernel_patches/fs/susfs.c" || {
    echo "[!] SUSFS v2.3.0 does not implement $symbol; refusing an ABI-only shim" >&2
    exit 1
  }
done

bash scripts/susfs/integrate-native.sh "$S4K_DIR" "$KROOT"

python3 - "$KROOT/include/linux/susfs_def.h" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
commands = {
    "CMD_SUSFS_SET_SUS_PATH_UID_FILTER": "0x55554",
    "CMD_SUSFS_SET_PRIORITY_UID_FILTER": "0x60030",
}
missing = [(name, value) for name, value in commands.items()
           if not re.search(r"^\\s*#\\s*define\\s+" + re.escape(name) + r"\\b", text, re.M)]
if missing:
    guard = re.search(r"^(#\\s*define\\s+\\w+_H\\b[^\\n]*\\n)", text, re.M)
    if not guard:
        guard = re.search(r"^(#\\s*define\\s+\\w+\\b[^\\n]*\\n)", text, re.M)
    if not guard:
        raise SystemExit("[!] cannot find include guard in susfs_def.h")
    block = "".join(f"#ifndef {name}\\n#define {name} {value}\\n#endif\\n"
                    for name, value in missing)
    text = text[:guard.end()] + block + text[guard.end():]
    path.write_text(text)
    print("[+] added BakaSU SUSFS command IDs to susfs_def.h")
else:
    print("[+] BakaSU SUSFS command IDs already present")
PY
