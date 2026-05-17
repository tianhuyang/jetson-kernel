#!/usr/bin/env bash
set -euo pipefail
# Build and install requested traffic-control modules on a Jetson device.
# Default behavior keeps /boot/Image unchanged and only installs modules.

SOURCE_SYNC_REMOTE="/tmp/source_sync.sh"
JETSON_L4T_TAG="${JETSON_L4T_TAG:-}"
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
    "/usr/src/linux-headers-${krel}-ubuntu22.04_aarch64/3rdparty/canonical/linux-jammy/kernel-source"
    "$HOME/nvidia/Linux_for_Tegra/source/kernel/kernel-jammy-src"
    "$HOME/nvidia/Linux_for_Tegra/source/kernel/kernel"
    "$HOME/kernel/kernel-jammy-src"
    "$HOME/kernel"
  )
  local d
  for d in "${candidates[@]}"; do
    if [[ -f "${d}/Makefile" && -f "${d}/net/sched/sch_htb.c" && -f "${d}/net/sched/sch_tbf.c" && -f "${d}/net/sched/sch_cake.c" && -f "${d}/net/sched/cls_u32.c" && -f "${d}/net/sched/cls_matchall.c" && -f "${d}/net/sched/act_police.c" ]]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

nv_release_key() {
  local major=""
  local rev_major=""
  local rev_minor=""

  if [[ -f /etc/nv_tegra_release ]]; then
    local line
    line="$(head -n 1 /etc/nv_tegra_release)"
    major="$(printf '%s' "$line" | sed -n 's/.*# R\([0-9]\+\).*/\1/p')"
    rev_major="$(printf '%s' "$line" | sed -n 's/.*REVISION: \([0-9]\+\)\..*/\1/p')"
    rev_minor="$(printf '%s' "$line" | sed -n 's/.*REVISION: [0-9]\+\.\([0-9]\+\).*/\1/p')"
  fi

  if [[ -n "$major" && -n "$rev_major" && -n "$rev_minor" ]]; then
    printf 'r%s%s%s' "$major" "$rev_major" "$rev_minor"
    return 0
  fi

  return 1
}

extract_public_sources_url() {
  local html_file="$1"
  tr '"' '\n' <"$html_file" | grep -E '^https://.*public_sources\.tbz2(\?.*)?$' | head -n 1 || true
}

nv_release_tag() {
  local release_key
  release_key="$(nv_release_key || true)"
  if [[ -z "$release_key" ]]; then
    return 1
  fi

  # Convert r3647 -> jetson_36.4.7 (preferred for gitlab nv-tegra mirrors)
  printf 'jetson_%s.%s.%s' "${release_key:1:2}" "${release_key:3:1}" "${release_key:4}"
}

nv_release_tag_alt() {
  local release_key
  release_key="$(nv_release_key || true)"
  if [[ -z "$release_key" ]]; then
    return 1
  fi

  # Alternate tag style used by some trees: r3647 -> tegra-l4t-r36.4.7
  printf 'tegra-l4t-r%s.%s.%s' "${release_key:1:2}" "${release_key:3:1}" "${release_key:4}"
}

fetch_kernel_src_with_source_sync() {
  local workdir="$HOME/jetson-kernel-src"
  local source_sync_path="$workdir/source_sync.sh"
  local tag
  local alt_tag=""
  local sync_log="$workdir/source_sync.log"

  mkdir -p "$workdir"
  cd "$workdir"

  if [[ -f "$SOURCE_SYNC_REMOTE" ]]; then
    cp -f "$SOURCE_SYNC_REMOTE" "$source_sync_path"
    chmod +x "$source_sync_path"
  elif [[ -x "./source_sync.sh" ]]; then
    source_sync_path="./source_sync.sh"
  else
    echo "ERROR: source_sync.sh not found (expected at $SOURCE_SYNC_REMOTE)." >&2
    return 1
  fi

  tag="${JETSON_L4T_TAG}"
  if [[ -z "$tag" ]]; then
    tag="$(nv_release_tag || true)"
    alt_tag="$(nv_release_tag_alt || true)"
  fi

  echo "No local kernel source tree found. Retrieving source via source_sync.sh..." >&2

  if [[ -n "$tag" ]]; then
    echo "Running: ./source_sync.sh -d ${workdir} -k -t ${tag}" >&2
    if ! GIT_TERMINAL_PROMPT=0 "$source_sync_path" -e -d "$workdir" -k -t "$tag" >"$sync_log" 2>&1; then
      if [[ -n "$alt_tag" && "$alt_tag" != "$tag" ]]; then
        echo "Primary tag failed; retrying with alternate tag: ${alt_tag}" >&2
        if ! GIT_TERMINAL_PROMPT=0 "$source_sync_path" -e -d "$workdir" -k -t "$alt_tag" >"$sync_log" 2>&1; then
          echo "Tag retries failed; falling back to source_sync without -t." >&2
          if ! GIT_TERMINAL_PROMPT=0 "$source_sync_path" -e -d "$workdir" -k >"$sync_log" 2>&1; then
            echo "ERROR: source_sync failed; last log lines:" >&2
            tail -n 40 "$sync_log" >&2 || true
            return 1
          fi
        fi
      else
        echo "Tag retry unavailable; falling back to source_sync without -t." >&2
        if ! GIT_TERMINAL_PROMPT=0 "$source_sync_path" -e -d "$workdir" -k >"$sync_log" 2>&1; then
          echo "ERROR: source_sync failed; last log lines:" >&2
          tail -n 40 "$sync_log" >&2 || true
          return 1
        fi
      fi
    fi
  else
    echo "WARN: unable to infer L4T tag from /etc/nv_tegra_release; running without -t." >&2
    echo "Running: ./source_sync.sh -d ${workdir} -k" >&2
    if ! GIT_TERMINAL_PROMPT=0 "$source_sync_path" -e -d "$workdir" -k >"$sync_log" 2>&1; then
      echo "ERROR: source_sync failed; last log lines:" >&2
      tail -n 40 "$sync_log" >&2 || true
      return 1
    fi
  fi

  local src_dir="$workdir/kernel/kernel-jammy-src"

  if [[ -z "$src_dir" || ! -f "$src_dir/Makefile" || ! -f "$src_dir/net/sched/sch_htb.c" || ! -f "$src_dir/net/sched/sch_tbf.c" || ! -f "$src_dir/net/sched/sch_cake.c" || ! -f "$src_dir/net/sched/cls_u32.c" || ! -f "$src_dir/net/sched/cls_matchall.c" || ! -f "$src_dir/net/sched/act_police.c" ]]; then
    echo "ERROR: source_sync did not create a usable kernel tree at ${src_dir}." >&2
    return 1
  fi

  echo "$src_dir"
}

ensure_writable_kernel_src() {
  local src_dir="$1"
  local probe_file="${src_dir}/.write_test.$$"

  if touch "$probe_file" >/dev/null 2>&1; then
    rm -f "$probe_file"
    echo "$src_dir"
    return 0
  fi

  local build_dir="$HOME/jetson-kernel-build/$(basename "$src_dir")"
  mkdir -p "$HOME/jetson-kernel-build"
  echo "Kernel source is not writable, copying to ${build_dir}" >&2
  rsync -a --delete "$src_dir/" "$build_dir/"
  echo "$build_dir"
}

ensure_build_dependencies() {
  need_cmd apt-get
  echo "Installing kernel build dependencies..." >&2
  sudo_run apt-get update -y >/dev/null
  sudo_run apt-get install -y build-essential bc bison flex libssl-dev libelf-dev >/dev/null
}

detect_localversion() {
  local ksrc="$1"
  local krel="$2"
  local base

  base="$(make -s -C "$ksrc" kernelversion)"
  if [[ "$krel" == "$base"* ]]; then
    printf '%s' "${krel#$base}"
    return 0
  fi

  printf ''
}

enable_tc_symbols() {
  local ksrc="$1"
  if [[ ! -x "${ksrc}/scripts/config" ]]; then
    make -C "$ksrc" scripts >/dev/null
  fi
  "${ksrc}/scripts/config" --file "${ksrc}/.config" --module NET_SCH_HTB
  "${ksrc}/scripts/config" --file "${ksrc}/.config" --module NET_SCH_TBF
  "${ksrc}/scripts/config" --file "${ksrc}/.config" --module NET_SCH_CAKE
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
  local mods=(sch_htb sch_tbf sch_cake act_police cls_u32 cls_matchall)
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

report_target_modules() {
  local mods=(sch_htb sch_tbf sch_cake act_police cls_u32 cls_matchall)
  local m
  echo "Installed module details:"
  for m in "${mods[@]}"; do
    local module_path
    local vermagic
    module_path="$(modinfo -n "$m" 2>/dev/null || true)"
    vermagic="$(modinfo -F vermagic "$m" 2>/dev/null || true)"
    echo "  ${m}:"
    echo "    path: ${module_path:-<unknown>}"
    echo "    vermagic: ${vermagic:-<unknown>}"
  done
}

tc_smoke_test() {
  local dev="tcmodtest0"

  echo "Running tc smoke test on ${dev}..."
  sudo_run ip link del "$dev" >/dev/null 2>&1 || true

  if ! sudo_run ip link add "$dev" type dummy; then
    echo "ERROR: failed to create dummy interface for tc smoke test." >&2
    return 1
  fi
  if ! sudo_run ip link set "$dev" up; then
    sudo_run ip link del "$dev" >/dev/null 2>&1 || true
    echo "ERROR: failed to bring up dummy interface for tc smoke test." >&2
    return 1
  fi

  if ! sudo_run tc qdisc add dev "$dev" root handle 1: htb default 1; then
    sudo_run ip link del "$dev" >/dev/null 2>&1 || true
    echo "ERROR: failed to add htb qdisc in tc smoke test." >&2
    return 1
  fi
  if ! sudo_run tc class add dev "$dev" parent 1: classid 1:1 htb rate 100mbit ceil 100mbit; then
    sudo_run ip link del "$dev" >/dev/null 2>&1 || true
    echo "ERROR: failed to add htb class in tc smoke test." >&2
    return 1
  fi
  if ! sudo_run tc qdisc add dev "$dev" parent 1:1 handle 10: tbf rate 50mbit burst 64kb latency 50ms; then
    sudo_run ip link del "$dev" >/dev/null 2>&1 || true
    echo "ERROR: failed to add tbf qdisc in tc smoke test." >&2
    return 1
  fi

  if ! sudo_run tc qdisc add dev "$dev" ingress; then
    sudo_run ip link del "$dev" >/dev/null 2>&1 || true
    echo "ERROR: failed to add ingress qdisc in tc smoke test." >&2
    return 1
  fi
  if ! sudo_run tc filter add dev "$dev" ingress prio 10 protocol ip matchall action police rate 10mbit burst 100k drop; then
    sudo_run ip link del "$dev" >/dev/null 2>&1 || true
    echo "ERROR: failed to add matchall+police filter in tc smoke test." >&2
    return 1
  fi
  if ! sudo_run tc filter add dev "$dev" parent 1: protocol ip prio 20 u32 match ip dst 127.0.0.1/32 flowid 1:1; then
    sudo_run ip link del "$dev" >/dev/null 2>&1 || true
    echo "ERROR: failed to add u32 filter in tc smoke test." >&2
    return 1
  fi

  sudo_run tc qdisc show dev "$dev" >/dev/null
  sudo_run tc filter show dev "$dev" ingress >/dev/null
  sudo_run tc filter show dev "$dev" parent 1: >/dev/null
  sudo_run ip link del "$dev" >/dev/null 2>&1 || true
  echo "tc smoke test passed."
}
need_cmd make
need_cmd rsync
need_cmd zcat
need_cmd grep
need_cmd sed
need_cmd tr
need_cmd git
need_cmd ip
need_cmd tc
need_cmd modinfo
need_cmd modprobe
need_cmd sudo
need_cmd apt-get
KREL="$(uname -r)"
NPROC="$(getconf _NPROCESSORS_ONLN)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/jetson-tc-modules-${TIMESTAMP}"

if [[ -n "${https_proxy:-}" ]]; then
  echo "Using proxy from https_proxy for remote network operations."
fi
KERNEL_SRC="$(pick_kernel_src "$KREL" || true)"
if [[ -z "$KERNEL_SRC" ]]; then
  if KERNEL_SRC="$(fetch_kernel_src_with_source_sync)"; then
    :
  else
    KERNEL_SRC=""
  fi
fi

if [[ -z "$KERNEL_SRC" ]]; then
  cat >&2 <<EOF2
ERROR: No usable kernel source tree found for ${KREL}.
Expected one of:
  /usr/src/linux-source-${KREL}
  /usr/src/linux-headers-${KREL}
  /usr/src/kernel/kernel-${KREL}
or an L4T source tree under ~/nvidia/Linux_for_Tegra/source/kernel/
or source retrieval via ./source_sync.sh -k -t <tag> to succeed.
EOF2
  exit 1
fi
KERNEL_SRC="$(ensure_writable_kernel_src "$KERNEL_SRC")"
LOCALVERSION="$(detect_localversion "$KERNEL_SRC" "$KREL")"

echo "Using kernel source: ${KERNEL_SRC}"
echo "Using LOCALVERSION: ${LOCALVERSION:-<empty>}"
ensure_build_dependencies
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
make -C "$KERNEL_SRC" LOCALVERSION="$LOCALVERSION" olddefconfig >/dev/null
make -C "$KERNEL_SRC" LOCALVERSION="$LOCALVERSION" prepare modules_prepare >/dev/null
# Build and install only net/sched modules by default.
make -C "$KERNEL_SRC" LOCALVERSION="$LOCALVERSION" -j"$NPROC" M=net/sched modules
sudo_run make -C "$KERNEL_SRC" LOCALVERSION="$LOCALVERSION" M=net/sched modules_install
sudo_run depmod -a "$KREL"
if verify_modules; then
  report_target_modules
  tc_smoke_test
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
make -C "$KERNEL_SRC" LOCALVERSION="$LOCALVERSION" -j"$NPROC"
sudo_run make -C "$KERNEL_SRC" LOCALVERSION="$LOCALVERSION" modules_install
sudo_run cp -a "${KERNEL_SRC}/arch/arm64/boot/Image" /boot/Image
sudo_run depmod -a
echo "Fallback kernel image installed at /boot/Image"
echo "Previous image backup: /boot/Image.pre-tcmods-${TIMESTAMP}"
echo "Quick rollback script: ${BACKUP_DIR}/quick_rollback.sh"
