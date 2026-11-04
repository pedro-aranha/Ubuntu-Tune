#!/usr/bin/env bash
# =============================================================================
# ubuntu_tune.sh  —  Suspend / Hibernate fixes + Battery optimization
# Target: ASUS TUF Gaming A15 (FA506NFR) · Ryzen 7 7435HS (NO iGPU) · RTX 2050 4GB · Ubuntu 26.10
#
# Usage:
#   sudo ./ubuntu_tune.sh diagnose     # read-only: prints the current state (changes nothing)
#   sudo ./ubuntu_tune.sh sleep        # fixes suspend (NVIDIA, wakeups, Wi-Fi)
#   sudo ./ubuntu_tune.sh hibernate    # sets up hibernation (swapfile + resume=)
#   sudo ./ubuntu_tune.sh battery      # TLP + amd-pstate + turbo/ASPM + charge limit (no iGPU)
#   sudo ./ubuntu_tune.sh lid          # lid close => suspend-then-hibernate (only AFTER testing hibernate)
#   sudo ./ubuntu_tune.sh all          # sleep + hibernate + battery
#   sudo ./ubuntu_tune.sh revert       # undoes everything the script created/changed
#
# Optional variables, e.g.: sudo CHARGE_LIMIT=70 BOOST_ON_BAT=1 ./ubuntu_tune.sh battery
# =============================================================================
set -euo pipefail

# ------------------------------- configuration -------------------------------
CHARGE_LIMIT="${CHARGE_LIMIT:-80}"          # max charge in % (100 = no limit)
WAKE_DISABLE="${WAKE_DISABLE:-XHC0 XHC1}"   # ACPI wakeup sources to disable ("" = none)
BATTERY_MODE="${BATTERY_MODE:-tlp}"         # tlp | ppd (keeps GNOME's power-profiles-daemon)
BOOST_ON_BAT="${BOOST_ON_BAT:-0}"           # 0 = no CPU turbo on battery (saves a lot)
PREFER_DEEP="${PREFER_DEEP:-0}"             # 1 = force S3 (deep) if the BIOS offers it
SWAP_EXTRA_GB="${SWAP_EXTRA_GB:-2}"         # swapfile = RAM + this value (GiB)
HIBERNATE_DELAY="${HIBERNATE_DELAY:-60min}" # suspend-then-hibernate: time until it hibernates
SWAPFILE="${SWAPFILE:-/swap.img}"
GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"
ASSUME_YES="${ASSUME_YES:-0}"
BK=/var/backups/tuf-tune

GRUB_DIRTY=0
INITRD_DIRTY=0

MANAGED_FILES=(
  /etc/modprobe.d/tuf-nvidia-sleep.conf
  /etc/modprobe.d/tuf-nvidia-runtimepm.conf
  /etc/udev/rules.d/80-tuf-nvidia-pm.rules
  /etc/systemd/system/systemd-suspend.service.d/tuf-nvidia.conf
  /etc/systemd/system/systemd-hibernate.service.d/tuf-nvidia.conf
  /etc/systemd/system/systemd-hybrid-sleep.service.d/tuf-nvidia.conf
  /etc/systemd/system/systemd-suspend-then-hibernate.service.d/tuf-nvidia.conf
  /usr/local/sbin/tuf-wakeup-fix
  /etc/systemd/system/tuf-wakeup-fix.service
  /etc/systemd/system-sleep/tuf-wifi.sh
  /etc/systemd/logind.conf.d/tuf-lid.conf
  /etc/systemd/sleep.conf.d/tuf-sleep.conf
  /etc/polkit-1/rules.d/10-tuf-hibernate.rules
  /etc/initramfs-tools/conf.d/resume
  /etc/tlp.d/01-tuf-a15.conf
  /usr/local/sbin/tuf-charge-limit
  /etc/systemd/system/tuf-charge-limit.service
)

# -------------------------------- helpers ------------------------------------
c_ok()   { printf '\e[32m✔\e[0m %s\n' "$*"; }
c_warn() { printf '\e[33m⚠\e[0m %s\n' "$*"; }
c_info() { printf '\e[36m→\e[0m %s\n' "$*"; }
c_err()  { printf '\e[31m✘\e[0m %s\n' "$*" >&2; }

need_root() { [[ $EUID -eq 0 ]] || { c_err "Run with sudo."; exit 1; }; }

confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  local a; read -rp "$1 [y/N] " a
  [[ "$a" =~ ^[yY]$ ]]
}

backup_once() { # $1 = existing file
  [[ -e "$1" ]] || return 0
  local dst="$BK$1.orig"
  [[ -e "$dst" ]] && return 0
  mkdir -p "$(dirname "$dst")"
  cp -a "$1" "$dst"
}

write_file() { # $1 = destination ; content via stdin
  mkdir -p "$(dirname "$1")"
  backup_once "$1"
  cat > "$1"
}

has_nvidia() { modinfo nvidia &>/dev/null || command -v nvidia-smi &>/dev/null; }

set_kparam() { # $1 = key ; $2 = full token (empty = just remove)
  local key="$1" tok="${2:-}"
  if [[ ! -f "$GRUB_FILE" ]]; then
    c_warn "No $GRUB_FILE (not GRUB?). Add this to the kernel cmdline manually: ${tok:-<remove $key>}"
    return 0
  fi
  backup_once "$GRUB_FILE"
  local line cur new="" w
  line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)"
  cur="${line#*=}"; cur="${cur#[\"\']}"; cur="${cur%[\"\']}"
  for w in $cur; do
    [[ "$w" == "$key" || "$w" == "$key="* ]] || new+="$w "
  done
  [[ -n "$tok" ]] && new+="$tok"
  new="${new% }"
  if [[ -n "$line" ]]; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"|" "$GRUB_FILE"
  else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"" >> "$GRUB_FILE"
  fi
  GRUB_DIRTY=1
}

finalize() {
  systemctl daemon-reload
  if (( GRUB_DIRTY ));   then c_info "update-grub…";       update-grub; fi
  if (( INITRD_DIRTY )); then c_info "update-initramfs…";  update-initramfs -u -k all; fi
  echo
  c_ok "Done. REBOOT the laptop to apply everything."
}

# -------------------------------- diagnose -----------------------------------
diagnose() {
  echo "=== System ==="
  echo "Model  : $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  echo "BIOS   : $(cat /sys/class/dmi/id/bios_version 2>/dev/null) ($(cat /sys/class/dmi/id/bios_date 2>/dev/null))"
  echo "Kernel : $(uname -r)"
  echo "Cmdline: $(cat /proc/cmdline)"

  echo; echo "=== Sleep states ==="
  echo "state     : $(cat /sys/power/state 2>/dev/null)"
  echo "mem_sleep : $(cat /sys/power/mem_sleep 2>/dev/null)   (brackets = active)"
  echo "disk      : $(cat /sys/power/disk 2>/dev/null)"

  echo; echo "=== Hibernation ==="
  free -h | awk 'NR==2{print "RAM: "$2}'
  swapon --show || true
  echo "Lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null || echo n/a)"
  mokutil --sb-state 2>/dev/null || true
  echo "Root filesystem: $(findmnt -no FSTYPE /)"

  echo; echo "=== NVIDIA ==="
  lsmod | grep -E '^nvidia' | head -3 || echo "nvidia module not loaded"
  prime-select query 2>/dev/null || true
  grep -E 'PreserveVideoMemory|DynamicPower|TemporaryFilePath' /proc/driver/nvidia/params 2>/dev/null \
    || echo "(no /proc/driver/nvidia/params)"
  systemctl is-enabled nvidia-suspend nvidia-resume nvidia-hibernate 2>&1 || true

  echo; echo "=== Wi-Fi ==="
  lspci -nnk 2>/dev/null | grep -iA3 -E 'network|wireless' | head -8 || true

  echo; echo "=== Enabled ACPI wakeup sources ==="
  grep '\*enabled' /proc/acpi/wakeup || true

  echo; echo "=== CPU ==="
  echo "driver : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo n/a)"
  echo "gov    : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  echo "EPP    : $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo n/a)"
  echo "profile: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo n/a)  [choices: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || echo n/a)]"

  echo; echo "=== Battery ==="
  for f in /sys/class/power_supply/*/charge_control_end_threshold; do
    [[ -e "$f" ]] && echo "$f = $(cat "$f")"
  done
  echo "TLP: $(systemctl is-active tlp 2>/dev/null || true) | PPD: $(systemctl is-active power-profiles-daemon 2>/dev/null || true)"

  echo; echo "=== Recent suspend/resume errors (kernel) ==="
  local b
  for b in 0 -1; do
    echo "--- boot $b ---"
    journalctl -b "$b" -k -o short-monotonic --no-pager 2>/dev/null \
      | grep -iE 'PM: (suspend|hibernation)|Freezing|nvidia.*(suspend|resume|fail|error)|amdgpu.*(suspend|resume|fail|error|timeout)|mt7921.*(fail|timeout|error)|failed to' \
      | tail -n 25 || true
  done

  echo
  c_info "Tip: an outdated BIOS causes a lot of sleep problems. Check: fwupdmgr refresh && fwupdmgr get-updates"
  c_info "If problems persist after the script, run 'diagnose' right after a failure and keep the output."
}

# ---------------------------------- sleep ------------------------------------
fix_sleep() {
  c_info "Fixing suspend…"

  if has_nvidia; then
    write_file /etc/modprobe.d/tuf-nvidia-sleep.conf <<'EOF'
# Preserve the GPU's VRAM across suspend/resume (avoids black screen/hang on resume)
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
options nvidia-drm modeset=1
EOF
    local u
    for u in nvidia-suspend nvidia-resume nvidia-hibernate; do
      if systemctl list-unit-files "$u.service" --no-legend 2>/dev/null | grep -q .; then
        systemctl enable "$u.service" >/dev/null 2>&1 || true
      fi
    done
    INITRD_DIRTY=1
    c_ok "NVIDIA: PreserveVideoMemoryAllocations + nvidia-suspend/resume/hibernate services"
  else
    c_warn "Proprietary NVIDIA driver not found — skipped the GPU tweaks (sudo ubuntu-drivers install)."
  fi

  # systemd >= 256 freezes user sessions, which breaks the proprietary driver in some cases
  local s
  for s in systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate; do
    write_file "/etc/systemd/system/$s.service.d/tuf-nvidia.conf" <<'EOF'
[Service]
Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false"
EOF
  done
  c_ok "systemd: SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false on the sleep services"

  # Spurious wakeups (in a backpack / lid closed): disable USB wakeups (internal keyboard and lid still wake it)
  if [[ -n "$WAKE_DISABLE" ]]; then
    write_file /usr/local/sbin/tuf-wakeup-fix <<'EOF'
#!/bin/bash
# Disables ACPI wakeup for the devices passed as arguments (if enabled)
for dev in "$@"; do
  if grep -qE "^${dev}[[:space:]].*\*enabled" /proc/acpi/wakeup; then
    echo "$dev" > /proc/acpi/wakeup
  fi
done
EOF
    chmod 755 /usr/local/sbin/tuf-wakeup-fix
    write_file /etc/systemd/system/tuf-wakeup-fix.service <<EOF
[Unit]
Description=Disable spurious ACPI wakeup sources
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tuf-wakeup-fix $WAKE_DISABLE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now tuf-wakeup-fix.service >/dev/null 2>&1 || true
    c_ok "Wakeup disabled for: $WAKE_DISABLE (a USB mouse no longer wakes the laptop)"
  fi

  # MediaTek MT7921 Wi-Fi often dies after resume: reload the module around sleep
  if lsmod | grep -q '^mt7921e'; then
    write_file /etc/systemd/system-sleep/tuf-wifi.sh <<'EOF'
#!/bin/sh
# Reload the MT7921 Wi-Fi driver around sleep
case "$1" in
  pre)  modprobe -r mt7921e 2>/dev/null ;;
  post) modprobe mt7921e 2>/dev/null ;;
esac
exit 0
EOF
    chmod 755 /etc/systemd/system-sleep/tuf-wifi.sh
    c_ok "Wi-Fi hook (mt7921e) installed"
  fi

  # S3 (deep) instead of s2idle: optional
  if [[ "$PREFER_DEEP" == 1 ]]; then
    if grep -qw deep /sys/power/mem_sleep; then
      set_kparam mem_sleep_default "mem_sleep_default=deep"
      c_ok "Kernel param mem_sleep_default=deep"
    else
      c_warn "The BIOS only offers s2idle (no S3). Nothing to do here."
    fi
  else
    c_info "Current mem_sleep: $(cat /sys/power/mem_sleep) (use PREFER_DEEP=1 to try S3 if 'deep' shows up)"
  fi
}

# -------------------------------- hibernate ----------------------------------
fix_hibernate() {
  c_info "Setting up hibernation…"

  local lock; lock="$(cat /sys/kernel/security/lockdown 2>/dev/null || true)"
  if [[ "$lock" == *"[integrity]"* || "$lock" == *"[confidentiality]"* ]]; then
    c_warn "Kernel lockdown is active (Secure Boot) — the kernel BLOCKS hibernation."
    c_warn "To hibernate: disable Secure Boot in the BIOS (and re-sign/adjust the NVIDIA driver if you use MOK)."
  fi

  local ram_kb ram_bytes need_bytes
  ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  ram_bytes=$(( ram_kb * 1024 ))
  need_bytes=$(( ram_bytes + SWAP_EXTRA_GB * 1024 * 1024 * 1024 ))

  local name type size resume_dev="" resume_uuid="" resume_offset=""
  while read -r name type size; do
    if [[ -z "${name:-}" || "$name" == /dev/zram* ]]; then continue; fi
    if [[ "$type" == partition && "$size" -ge "$ram_bytes" && -z "$resume_dev" ]]; then
      resume_dev="$name"
    elif [[ "$type" == file ]]; then
      SWAPFILE="$name"
    fi
  done < <(swapon --noheadings --raw --bytes --show=NAME,TYPE,SIZE)

  if [[ -n "$resume_dev" ]]; then
    c_ok "Using existing swap partition: $resume_dev"
    resume_uuid="$(blkid -s UUID -o value "$resume_dev")"
  else
    local fstype; fstype="$(findmnt -no FSTYPE -T "$(dirname "$SWAPFILE")")"
    if [[ "$fstype" != ext4 ]]; then
      c_err "Filesystem is '$fstype'. This script only automates swapfiles on ext4."
      c_err "(btrfs/zfs need their own procedure.) Aborting the hibernation part."
      return 1
    fi

    local cur_size=0
    [[ -f "$SWAPFILE" ]] && cur_size="$(stat -c %s "$SWAPFILE")"
    if (( cur_size < ram_bytes )); then
      local avail; avail="$(df --output=avail -B1 / | tail -1 | tr -d ' ')"
      if (( avail < need_bytes + 5 * 1024 * 1024 * 1024 )); then
        c_err "Not enough disk space for a $(( need_bytes / 1024 / 1024 / 1024 )) GiB swapfile."
        return 1
      fi
      if ! confirm "Recreate $SWAPFILE with $(( need_bytes / 1024 / 1024 / 1024 )) GiB (RAM + ${SWAP_EXTRA_GB} GiB)?"; then
        c_warn "Cancelled by user."; return 1
      fi
      backup_once /etc/fstab
      if swapon --noheadings --show=NAME | grep -qx "$SWAPFILE"; then swapoff "$SWAPFILE"; fi
      rm -f "$SWAPFILE"
      fallocate -l "$need_bytes" "$SWAPFILE"
      chmod 600 "$SWAPFILE"
      mkswap "$SWAPFILE" >/dev/null
      swapon "$SWAPFILE"
      grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
      c_ok "Swapfile recreated: $SWAPFILE ($(( need_bytes / 1024 / 1024 / 1024 )) GiB)"
    else
      c_ok "Existing swapfile already fits the RAM ($(( cur_size / 1024 / 1024 / 1024 )) GiB)."
    fi

    resume_uuid="$(findmnt -no UUID -T "$SWAPFILE")"
    resume_offset="$(filefrag -v "$SWAPFILE" | awk '$1=="0:"' | grep -oE '[0-9]+' | sed -n 4p)"
    if [[ -z "$resume_uuid" || -z "$resume_offset" ]]; then
      c_err "Could not determine the swapfile's UUID/offset."; return 1
    fi
    if [[ "$(findmnt -no SOURCE /)" == /dev/mapper/* ]]; then
      c_warn "Root on LVM/LUKS: make sure the initramfs unlocks the volume before resume."
    fi
  fi

  set_kparam resume "resume=UUID=$resume_uuid"
  if [[ -n "$resume_offset" ]]; then
    set_kparam resume_offset "resume_offset=$resume_offset"
  else
    set_kparam resume_offset ""
  fi

  write_file /etc/initramfs-tools/conf.d/resume <<EOF
RESUME=UUID=$resume_uuid
EOF
  INITRD_DIRTY=1

  # Allow hibernating via logind/GNOME without a password prompt
  write_file /etc/polkit-1/rules.d/10-tuf-hibernate.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.login1.hibernate" ||
      action.id == "org.freedesktop.login1.hibernate-multiple-sessions" ||
      action.id == "org.freedesktop.login1.hibernate-ignore-inhibit" ||
      action.id == "org.freedesktop.login1.handle-hibernate-key") {
    return polkit.Result.YES;
  }
});
EOF

  c_ok "resume=UUID=$resume_uuid ${resume_offset:+resume_offset=$resume_offset }configured"
  c_info "After rebooting, TEST:  systemctl hibernate   (then run 'lid' if it works)"
  c_info "GNOME doesn't show 'Hibernate' in its menu by default — use the command above (or an extension)."
}

# ----------------------------------- lid -------------------------------------
fix_lid() {
  c_info "Configuring lid close => suspend-then-hibernate…"
  write_file /etc/systemd/logind.conf.d/tuf-lid.conf <<'EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
EOF
  write_file /etc/systemd/sleep.conf.d/tuf-sleep.conf <<EOF
[Sleep]
HibernateDelaySec=$HIBERNATE_DELAY
EOF
  c_ok "Lid close on battery: suspends, then hibernates after $HIBERNATE_DELAY (zero drain). On AC: suspend only."
}

# --------------------------------- battery -----------------------------------
fix_battery() {
  c_info "Optimizing battery (mode: $BATTERY_MODE)…"
  c_info "This laptop has no iGPU: the RTX 2050 drives the display and never powers off. Gains come from CPU, PCIe, Wi-Fi, audio and the charge limit."

  # Clean up leftovers from older versions of this script (they assumed hybrid graphics)
  if [[ -e /etc/modprobe.d/tuf-nvidia-runtimepm.conf || -e /etc/udev/rules.d/80-tuf-nvidia-pm.rules ]]; then
    rm -f /etc/modprobe.d/tuf-nvidia-runtimepm.conf /etc/udev/rules.d/80-tuf-nvidia-pm.rules
    INITRD_DIRTY=1
    c_ok "Removed NVIDIA runtime-PM tweaks from older versions"
  fi
  if command -v prime-select >/dev/null 2>&1 && [[ "$(prime-select query 2>/dev/null)" == on-demand ]]; then
    prime-select nvidia >/dev/null 2>&1 || true
    INITRD_DIRTY=1
    c_ok "PRIME restored to 'nvidia' (the only valid mode without an iGPU)"
  fi

  local drv; drv="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo none)"

  # amd-pstate EPP (fine-grained power control on Zen 3+)
  if [[ "$drv" != amd-pstate-epp ]]; then
    set_kparam amd_pstate "amd_pstate=active"
    c_warn "Current driver: '$drv'. Added amd_pstate=active; REBOOT and run 'battery' again to tune the CPU."
  else
    c_ok "CPU already uses amd-pstate-epp"
  fi

  if [[ "$BATTERY_MODE" == tlp ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y tlp >/dev/null
    systemctl mask --now power-profiles-daemon.service >/dev/null 2>&1 || true

    local cpu_cfg pp_choices pp_cfg="" bat_profile=balanced p
    case "$drv" in
      amd-pstate-epp)
        cpu_cfg=$'CPU_SCALING_GOVERNOR_ON_AC=powersave\nCPU_SCALING_GOVERNOR_ON_BAT=powersave\nCPU_ENERGY_PERF_POLICY_ON_AC=balance_performance\nCPU_ENERGY_PERF_POLICY_ON_BAT=balance_power\nCPU_DRIVER_OPMODE_ON_AC=active\nCPU_DRIVER_OPMODE_ON_BAT=active' ;;
      *)
        cpu_cfg=$'CPU_SCALING_GOVERNOR_ON_AC=schedutil\nCPU_SCALING_GOVERNOR_ON_BAT=schedutil' ;;
    esac

    pp_choices="$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || true)"
    if [[ -n "$pp_choices" ]]; then
      for p in low-power quiet; do
        if [[ " $pp_choices " == *" $p "* ]]; then bat_profile="$p"; break; fi
      done
      pp_cfg=$'PLATFORM_PROFILE_ON_AC=balanced\nPLATFORM_PROFILE_ON_BAT='"$bat_profile"
    fi

    write_file /etc/tlp.d/01-tuf-a15.conf <<EOF
# Generated by ubuntu_tune.sh — ASUS TUF A15 (Ryzen 7 7435HS + RTX 2050, no iGPU)
TLP_ENABLE=1

# --- CPU ---
$cpu_cfg
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=$BOOST_ON_BAT
$pp_cfg

# --- PCIe / devices ---
RUNTIME_PM_ON_AC=auto
RUNTIME_PM_ON_BAT=auto
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersave

# --- Wi-Fi / audio / USB ---
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=1
USB_AUTOSUSPEND=1
WOL_DISABLE=Y
EOF
    systemctl enable --now tlp.service >/dev/null 2>&1 || true
    tlp start >/dev/null 2>&1 || true
    c_ok "TLP installed/configured (power-profiles-daemon masked)"
  else
    systemctl unmask power-profiles-daemon.service >/dev/null 2>&1 || true
    systemctl enable --now power-profiles-daemon.service >/dev/null 2>&1 || true
    c_ok "Keeping power-profiles-daemon (use 'Power Saver' in the GNOME menu)"
  fi

  # Charge limit (preserves battery health)
  if (( CHARGE_LIMIT < 100 )); then
    write_file /usr/local/sbin/tuf-charge-limit <<'EOF'
#!/bin/bash
limit="${1:-80}"
for f in /sys/class/power_supply/*/charge_control_end_threshold; do
  [ -w "$f" ] && echo "$limit" > "$f"
done
exit 0
EOF
    chmod 755 /usr/local/sbin/tuf-charge-limit
    write_file /etc/systemd/system/tuf-charge-limit.service <<EOF
[Unit]
Description=Battery charge limit ($CHARGE_LIMIT%)
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tuf-charge-limit $CHARGE_LIMIT

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF
    systemctl daemon-reload
    systemctl enable --now tuf-charge-limit.service >/dev/null 2>&1 || true
    if ls /sys/class/power_supply/*/charge_control_end_threshold >/dev/null 2>&1; then
      c_ok "Charge limit set to ${CHARGE_LIMIT}% (for travel: sudo tuf-charge-limit 100)"
    else
      c_warn "Kernel doesn't expose charge_control_end_threshold — charge limit unavailable."
    fi
  fi

  c_info "Manual tips: 60 Hz refresh rate on battery (Settings > Displays) saves ~1–2 W; brightness ≤ 50%."
}

# ---------------------------------- revert -----------------------------------
revert() {
  c_info "Reverting changes…"
  systemctl disable --now tuf-wakeup-fix.service tuf-charge-limit.service >/dev/null 2>&1 || true
  local f
  for f in "${MANAGED_FILES[@]}"; do
    if [[ -e "$BK$f.orig" ]]; then
      cp -a "$BK$f.orig" "$f"
    else
      rm -f "$f"
    fi
  done
  if [[ -e "$BK$GRUB_FILE.orig" ]]; then cp -a "$BK$GRUB_FILE.orig" "$GRUB_FILE"; GRUB_DIRTY=1; fi
  INITRD_DIRTY=1
  systemctl disable --now tlp.service >/dev/null 2>&1 || true
  systemctl unmask power-profiles-daemon.service >/dev/null 2>&1 || true
  systemctl enable --now power-profiles-daemon.service >/dev/null 2>&1 || true
  c_warn "The enlarged swapfile and its /etc/fstab line were NOT reverted (harmless)."
  finalize
}

# ----------------------------------- main ------------------------------------
case "${1:-help}" in
  diagnose)  need_root; diagnose ;;
  sleep)     need_root; fix_sleep; finalize ;;
  hibernate) need_root; fix_hibernate; finalize ;;
  battery)   need_root; fix_battery; finalize ;;
  lid)       need_root; fix_lid; finalize ;;
  all)       need_root; fix_sleep; fix_hibernate; fix_battery; finalize ;;
  revert)    need_root; revert ;;
  *)         sed -n '2,19p' "$0" ;;
esac