#!/usr/bin/env bash
set -euo pipefail
# Build and install requested traffic-control modules on a Jetson device.
# Default behavior keeps /boot/Image unchanged and only installs modules.
ALLOW_IMAGE_FALLBACK=0
if [[ "${1:-}" == "--allow-image-fallback" ]]; then
  ALLOW_IMAGE_FALLBACK=1
fi
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}
sudo_run() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return
  fi
  if [[ -n "${JETSON_PASS:-}" ]]; then
    printf '%s\n' "$JETSON_PASS" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}
pick_kernel_src() {
  local krel="$1"
  local candidates=(
    "/usr/src/linux-source-${krel}"
    "/usr/src/linux-headers-${krel}"
    "/usr/src/kernel/kernel-${krel}"
    "$HOME/nvidia/Linux_for_Tegra/source/kernel/kernel-jammy-src"
    "$HOME/nvidia/Linux_for_Tegra/source/kernel/kernel"
    "$HOME/kernel/kernel-jammy-src"
    "$HOME/kernel"
  )
  local d
  for d in "${candidates[@]}"; do
    if [[ -f "${d}/Makefile" && -d "${d}/net/sched" ]]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}
enable_tc_symbols() {
  local ksrc="$1"
  if [[ ! -x "${ksrc}/scripts/config" ]]; then
    make -C "$ksrc" scripts >/dev/null
  fi
  "${ksrc}/scripts/config" --file "${ksrc}/.config" --module NET_SCH_HTB
  "${ksrc}/scripts/config" --file "${ksrc}/.config" --module NET_SCH_TBF
  "${ksrc}/scripts/config" --file "${ksrc}/.config" --module NET_ACT_POLICE
  "${ksrc}/scripts/config" --file "${ksrc}/.config" --module NET_CLS_U32
  "${ksrc}/scripts/config" --file "${ksrc}/.config" --module NET_CLS_MATCHALL
}
quick_backup() {
  local krel="$1"
  local backup_root="$2"
  sudo_run mkdir -p "$backup_root"
  sudo_run cp -a /boot/extlinux/extlinux.conf "$backup_root/extlinux.conf.bak"
  # Capture existing module tree for fast rollback of the running kernel only.
  sudo_run rsync -a "/lib/modules/${krel}/" "$backup_root/modules-${krel}/"
  sudo_run tee "$backup_root/quick_rollback.sh" >/dev/null <<EOF2
#!/usr/bin/env bash
set -euo pipefail
KREL="${krel}"
BACKUP_DIR="${backup_root}"
if [[ "\${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo \$0"
  exit 1
fi
rsync -a --delete "\${BACKUP_DIR}/modules-\${KREL}/" "/lib/modules/\${KREL}/"
cp -a "\${BACKUP_DIR}/extlinux.conf.bak" /boot/extlinux/extlinux.conf
depmod -a "\${KREL}"
echo "Rollback complete for \${KREL}."
EOF2
  sudo_run chmod +x "$backup_root/quick_rollback.sh"
}
verify_modules() {
  local mods=(sch_htb sch_tbf act_police cls_u32 cls_matchall)
  local m
  for m in "${mods[@]}"; do
    if ! modinfo "$m" >/dev/null 2>&1; then
      echo "ERROR: module metadata not found for: $m" >&2
      return 1
    fi
    sudo_run modprobe "$m"
  done
  echo "Verified module load: ${mods[*]}"
}
need_cmd make
need_cmd rsync
need_cmd zcat
need_cmd modinfo
need_cmd modprobe
need_cmd sudo
KREL="$(uname -r)"
NPROC="$(getconf _NPROCESSORS_ONLN)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/jetson-tc-modules-${TIMESTAMP}"
KERNEL_SRC="$(pick_kernel_src "$KREL" || true)"
if [[ -z "$KERNEL_SRC" ]]; then
  cat >&2 <<EOF2
ERROR: No usable kernel source tree found for ${KREL}.
Expected one of:
  /usr/src/linux-source-${KREL}
  /usr/src/linux-headers-${KREL}
  /usr/src/kernel/kernel-${KREL}
or an L4T source tree under ~/nvidia/Linux_for_Tegra/source/kernel/
EOF2
  exit 1
fi
echo "Using kernel source: ${KERNEL_SRC}"
echo "Creating quick rollback bundle at ${BACKUP_DIR}"
quick_backup "$KREL" "$BACKUP_DIR"
if [[ -f /proc/config.gz ]]; then
  zcat /proc/config.gz >"${KERNEL_SRC}/.config"
elif [[ -f "/boot/config-${KREL}" ]]; then
  cp "/boot/config-${KREL}" "${KERNEL_SRC}/.config"
else
  echo "ERROR: cannot locate running kernel config" >&2
  exit 1
fi
enable_tc_symbols "$KERNEL_SRC"
make -C "$KERNEL_SRC" olddefconfig >/dev/null
# Build and install only net/sched modules by default.
make -C "$KERNEL_SRC" -j"$NPROC" M=net/sched modules
sudo_run make -C "$KERNEL_SRC" M=net/sched modules_install
sudo_run depmod -a "$KREL"
if verify_modules; then
  echo "Module-only deployment completed successfully."
  echo "Quick rollback script: ${BACKUP_DIR}/quick_rollback.sh"
  exit 0
fi
if [[ "$ALLOW_IMAGE_FALLBACK" -ne 1 ]]; then
  echo "ERROR: module verification failed and image fallback is disabled." >&2
  echo "Re-run with --allow-image-fallback to build/install full kernel image." >&2
  exit 1
fi
echo "Module verification failed, trying full kernel build fallback..."
sudo_run cp -a /boot/Image "/boot/Image.pre-tcmods-${TIMESTAMP}"
make -C "$KERNEL_SRC" -j"$NPROC"
sudo_run make -C "$KERNEL_SRC" modules_install
sudo_run cp -a "${KERNEL_SRC}/arch/arm64/boot/Image" /boot/Image
sudo_run depmod -a
echo "Fallback kernel image installed at /boot/Image"
echo "Previous image backup: /boot/Image.pre-tcmods-${TIMESTAMP}"
echo "Quick rollback script: ${BACKUP_DIR}/quick_rollback.sh"
