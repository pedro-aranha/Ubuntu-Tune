# ASUS TUF Gaming A15 — Linux suspend/hibernate & battery tuning
**Use at your own risk**

Script that fix suspend/hibernate problems and improve battery life on the **ASUS TUF Gaming A15 (FA506NFR)**:

| Script | Target |
|---|---|
| `ubuntu_tune.sh` | Ubuntu 26.10 (GNOME) |

**Target hardware:** Ryzen 7 7435HS · RTX 2050 4 GB · **no iGPU** (the NVIDIA GPU is the only GPU and drives the display).

> ⚠️ **Experimental.** These scripts modify kernel parameters, the initramfs, swap, systemd units and `/etc/fstab`. They have **not** been validated on other hardware than ASUS TUF Gaming A15 (FA506NFR). Run `diagnose` first, read the script, and make sure you have a way to recover (live USB) before using `hibernate` or `all`. **Use at your own risk**.

## What it does

### Suspend (`sleep`)
- **NVIDIA:** enables `NVreg_PreserveVideoMemoryAllocations=1` and the `nvidia-suspend` / `nvidia-resume` / `nvidia-hibernate` services to avoid black screens or hangs on resume.
- **systemd:** sets `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false` on the sleep services (workaround for systemd ≥ 256 with the proprietary driver).
- **Spurious wakeups:** disables the `XHC0`/`XHC1` ACPI wakeup sources (a USB mouse no longer wakes the laptop; keyboard and lid still do).
- **Wi-Fi:** if the MediaTek `mt7921e` driver is loaded, reloads it around sleep.
- **Optional:** `PREFER_DEEP=1` tries S3 (`mem_sleep_default=deep`) when the BIOS exposes it.

### Hibernate (`hibernate`)
- Creates/resizes a swapfile (RAM + 2 GiB by default, asks for confirmation), computes `resume=` / `resume_offset=`, updates the bootloader and initramfs.
- Ubuntu script: ext4 only.
- **Secure Boot must be off** — with kernel lockdown active, the kernel blocks hibernation. The scripts warn you if it is on.

### Lid (`lid`)
- Lid close on battery → suspend, then hibernate after `HIBERNATE_DELAY` (default 60 min). Only run this **after** you confirmed `systemctl hibernate` works.

### Battery (`battery`)
Because there is no iGPU, the NVIDIA GPU never powers off, so gains come from the CPU, PCIe, Wi-Fi, audio and the charge limit:
- `amd_pstate=active` (EPP) if the CPU isn't already using `amd-pstate-epp`.
- CPU turbo off on battery, PCIe ASPM `powersave` on battery (back to normal on AC).
- Wi-Fi and audio power saving.
- Charge limit (default 80%) via `charge_control_end_threshold`, if the kernel exposes it.
- **Ubuntu:** installs and configures TLP (masks `power-profiles-daemon`; use `BATTERY_MODE=ppd` to keep it).

## Usage (Ubuntu)

```bash
chmod +x ubuntu_tune.sh            
sudo ./ubuntu_tune.sh diagnose     # read-only, changes nothing
sudo ./ubuntu_tune.sh all          # sleep + hibernate + battery
sudo reboot
systemctl hibernate                 # test that it resumes correctly
sudo ./ubuntu_tune.sh lid          # only if hibernate worked
```

On Ubuntu, after the first reboot run `sudo ./tuf-a15-tune.sh battery` again so the CPU settings are tuned for the new `amd-pstate` driver.

Individual steps: `diagnose`, `sleep`, `hibernate`, `battery`, `lid`, `all`, `revert`.

## Configuration

Set variables on the command line, e.g.:

```bash
sudo CHARGE_LIMIT=70 BOOST_ON_BAT=1 ./tuf-a15-tune.sh battery
```

| Variable | Default | Description |
|---|---|---|
| `CHARGE_LIMIT` | `80` | Max charge in % (`100` = no limit) |
| `WAKE_DISABLE` | `XHC0 XHC1` | ACPI wakeup sources to disable (`""` = none) |
| `BOOST_ON_BAT` | `0` | `1` = keep CPU turbo on battery |
| `PREFER_DEEP` | `0` | `1` = try S3 (`deep`) if available |
| `SWAP_EXTRA_GB` | `2` | Swapfile size = RAM + this value |
| `HIBERNATE_DELAY` | `60min` | Time before suspend-then-hibernate hibernates |
| `ASSUME_YES` | `0` | `1` = skip confirmation prompts |
| `BATTERY_MODE` | `tlp` | *(Ubuntu)* `tlp` or `ppd` |
| `ASPM_BAT` | `powersave` |
| `NV_BAT_MAXCLOCK` | `0` |

To remove the charge limit before a trip: `sudo tuf-charge-limit 100`.

## Revert

```bash
sudo ./tuf-a15-tune.sh revert
```

Original versions of every file the script touches are saved under `/var/backups/tuf-tune/` the first time they are modified, and `revert` restores them (or deletes files the script created). The enlarged swapfile and its `/etc/fstab` line are **not** removed (harmless).

## Troubleshooting

- Update the BIOS first — an outdated BIOS is a common cause of sleep issues: `fwupdmgr refresh && fwupdmgr get-updates`.
- If suspend/hibernate still fails, run `sudo ./ubuntu_tune.sh diagnose` **right after a failure** and attach the output to an issue.
- Hibernate does nothing / system doesn't resume: check that Secure Boot is disabled and that `resume=` and `resume_offset=` appear in `/proc/cmdline`.

## Not for other models

These scripts assume this exact hardware. On laptops with an iGPU (hybrid graphics) the `battery` step does not apply as-is, and the Wi-Fi/wakeup tweaks may be unnecessary or wrong.
