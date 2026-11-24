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
exec bash scripts/susfs/integrate-native.sh "$S4K_DIR" "$KROOT"
