#!/usr/bin/env bash
set -euo pipefail

# Configure an Apple keyboard on Linux so the physical Mac modifier row behaves
# like a PC keyboard row:
#   physical fn   -> Control
#   physical ctrl -> Fn
#   physical opt  -> Meta/Super
#   physical cmd  -> Alt
#
# This uses the hid_apple kernel driver because Fn remapping is not reliable in
# user-space tools alone.

SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE=""
ACTION="apply"
RUNTIME_ONLY=0
PERSIST=1
PLASMA_META_LAUNCHER="auto"
RELOAD_HID_APPLE="auto"
MODPROBE_CONF="/etc/modprobe.d/maclinq-apple-physical-keys.conf"

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

log() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*"
}

usage() {
  cat <<'EOF'
Usage:
  kde-plasma6-apple-physical-keys.sh [apply|restore|status] [options]

Purpose:
  Make an Apple keyboard on Linux feel physically like a PC keyboard:
  - fn key acts as Ctrl
  - ctrl key acts as Fn
  - option key acts as Meta/Super
  - command key acts as Alt

Actions:
  apply      Apply the Maclinq Apple-keyboard remap
  restore    Remove the persistent remap and set hid_apple values back to 0
  status     Show current hid_apple values and relevant Plasma settings

Options:
  --config PATH                 Read settings from a shell-style config file
  --runtime-only                Apply only to the running kernel; do not persist
  --no-plasma-meta-launcher     Do not touch the Plasma "Meta opens launcher" setting
  --plasma-meta-launcher MODE   MODE is auto|on|off
  --reload-hid-apple MODE       MODE is auto|yes|no
  --help                        Show this help

Config file variables:
  PLASMA_META_LAUNCHER=auto|on|off
  RELOAD_HID_APPLE=auto|yes|no
  MODPROBE_CONF=/etc/modprobe.d/custom-name.conf

Notes:
  - This script targets KDE Plasma 6 on Ubuntu or similar Linux systems.
  - Persistent remapping uses a modprobe config for the hid_apple kernel module.
  - Runtime remapping uses /sys/module/hid_apple/parameters when available.
  - Some changes may require unplug/replug, module reload, or reboot.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "run as root (for example: sudo $SCRIPT_NAME $ACTION ...)"
  fi
}

read_config_file() {
  local path="$1"
  [[ -f "$path" ]] || die "config file not found: $path"
  # shellcheck disable=SC1090
  source "$path"
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      apply|restore|status)
        ACTION="$1"
        shift
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        shift
        [[ $# -gt 0 ]] || die "--config requires a path"
        CONFIG_FILE="$1"
        ;;
      --runtime-only)
        RUNTIME_ONLY=1
        PERSIST=0
        ;;
      --no-plasma-meta-launcher)
        PLASMA_META_LAUNCHER="off"
        ;;
      --plasma-meta-launcher)
        shift
        [[ $# -gt 0 ]] || die "--plasma-meta-launcher requires auto|on|off"
        PLASMA_META_LAUNCHER="$1"
        ;;
      --reload-hid-apple)
        shift
        [[ $# -gt 0 ]] || die "--reload-hid-apple requires auto|yes|no"
        RELOAD_HID_APPLE="$1"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done

  [[ "$PLASMA_META_LAUNCHER" =~ ^(auto|on|off)$ ]] || die "invalid PLASMA_META_LAUNCHER: $PLASMA_META_LAUNCHER"
  [[ "$RELOAD_HID_APPLE" =~ ^(auto|yes|no)$ ]] || die "invalid RELOAD_HID_APPLE: $RELOAD_HID_APPLE"
}

read_param() {
  local path="$1"
  if [[ -r "$path" ]]; then
    tr -d '\n' <"$path"
  else
    printf 'unavailable'
  fi
}

write_param() {
  local path="$1"
  local value="$2"

  [[ -e "$path" ]] || die "kernel parameter path not found: $path"
  if ! printf '%s' "$value" >"$path" 2>/dev/null; then
    die "failed to write '$value' to $path; the module may reject runtime writes, or your kernel may require a reload/reboot"
  fi
}

update_initramfs_if_available() {
  if command -v update-initramfs >/dev/null 2>&1; then
    log "updating initramfs so the remap survives reboot"
    update-initramfs -u
  else
    log "update-initramfs not found; persistent config was written, but you may need to rebuild initramfs manually on your distro"
  fi
}

write_modprobe_profile() {
  cat >"$MODPROBE_CONF" <<'EOF'
# Maclinq Apple keyboard physical-key remap
# Physical fn   -> Control
# Physical ctrl -> Fn
# Physical opt  -> Meta/Super
# Physical cmd  -> Alt
options hid_apple swap_fn_leftctrl=1 swap_opt_cmd=1
EOF
  log "wrote persistent hid_apple config to $MODPROBE_CONF"
}

remove_modprobe_profile() {
  if [[ -f "$MODPROBE_CONF" ]]; then
    rm -f "$MODPROBE_CONF"
    log "removed persistent hid_apple config from $MODPROBE_CONF"
  else
    log "persistent config already absent at $MODPROBE_CONF"
  fi
}

maybe_reload_hid_apple() {
  local mode="$1"

  if [[ ! -d /sys/module/hid_apple ]]; then
    if [[ "$mode" == "yes" ]]; then
      die "hid_apple is not currently loaded, so it cannot be reloaded"
    fi
    log "hid_apple is not currently loaded; remap will take effect when the module loads or after reboot"
    return 0
  fi

  case "$mode" in
    no)
      log "skipping hid_apple reload by request"
      ;;
    auto|yes)
      if command -v modprobe >/dev/null 2>&1; then
        log "reloading hid_apple so the new mapping applies immediately"
        modprobe -r hid_apple || die "failed to unload hid_apple; close active users of the Apple keyboard or rerun with --reload-hid-apple no and reboot later"
        modprobe hid_apple || die "failed to reload hid_apple; check dmesg for the module error"
      else
        [[ "$mode" == "yes" ]] && die "modprobe is required for --reload-hid-apple yes"
        log "modprobe not found; skipping module reload"
      fi
      ;;
  esac
}

apply_runtime_mapping() {
  local fn_param="/sys/module/hid_apple/parameters/swap_fn_leftctrl"
  local opt_param="/sys/module/hid_apple/parameters/swap_opt_cmd"

  if [[ ! -d /sys/module/hid_apple ]]; then
    log "hid_apple is not loaded right now; runtime mapping was skipped"
    return 0
  fi

  write_param "$fn_param" "1"
  write_param "$opt_param" "1"
  log "applied runtime hid_apple remap: swap_fn_leftctrl=1 swap_opt_cmd=1"
}

restore_runtime_mapping() {
  local fn_param="/sys/module/hid_apple/parameters/swap_fn_leftctrl"
  local opt_param="/sys/module/hid_apple/parameters/swap_opt_cmd"

  if [[ ! -d /sys/module/hid_apple ]]; then
    log "hid_apple is not loaded right now; runtime restore was skipped"
    return 0
  fi

  write_param "$fn_param" "0"
  write_param "$opt_param" "0"
  log "restored runtime hid_apple remap to swap_fn_leftctrl=0 swap_opt_cmd=0"
}

have_plasma_cli() {
  command -v kwriteconfig6 >/dev/null 2>&1
}

apply_plasma_meta_launcher() {
  local mode="$1"

  if [[ "$mode" == "off" ]]; then
    log "skipping Plasma Meta-launcher config by request"
    return 0
  fi

  if ! have_plasma_cli; then
    if [[ "$mode" == "on" ]]; then
      die "kwriteconfig6 is required to force a Plasma shortcut update, but it was not found"
    fi
    log "kwriteconfig6 not found; Plasma shortcut config was skipped"
    return 0
  fi

  kwriteconfig6 --file kwinrc --group ModifierOnlyShortcuts --key Meta \
    'org.kde.plasmashell,/PlasmaShell,activateLauncherMenu'
  log "configured Plasma so Meta alone opens the application launcher"
  log "you may need to log out and back in, or restart KWin/Plasma, for the shortcut change to appear"
}

disable_plasma_meta_launcher() {
  if ! have_plasma_cli; then
    log "kwriteconfig6 not found; Plasma shortcut restore was skipped"
    return 0
  fi

  kwriteconfig6 --file kwinrc --group ModifierOnlyShortcuts --key Meta ''
  log "cleared the Plasma Meta-only launcher shortcut"
  log "you may need to log out and back in, or restart KWin/Plasma, for the shortcut change to appear"
}

status() {
  local fn_value
  local opt_value
  local plasma_meta="unavailable"

  fn_value="$(read_param /sys/module/hid_apple/parameters/swap_fn_leftctrl)"
  opt_value="$(read_param /sys/module/hid_apple/parameters/swap_opt_cmd)"

  if command -v kreadconfig6 >/dev/null 2>&1; then
    plasma_meta="$(kreadconfig6 --file kwinrc --group ModifierOnlyShortcuts --key Meta 2>/dev/null || true)"
    [[ -n "$plasma_meta" ]] || plasma_meta="unset"
  fi

  cat <<EOF
$SCRIPT_NAME status
  hid_apple loaded: $([[ -d /sys/module/hid_apple ]] && echo yes || echo no)
  swap_fn_leftctrl: $fn_value
  swap_opt_cmd:     $opt_value
  persistent file:  $([[ -f "$MODPROBE_CONF" ]] && echo "$MODPROBE_CONF" || echo absent)
  Plasma Meta-only: $plasma_meta

Expected physical layout after apply:
  fn   -> Ctrl
  ctrl -> Fn
  opt  -> Meta/Super
  cmd  -> Alt
EOF
}

apply_action() {
  require_root

  if (( PERSIST )); then
    write_modprobe_profile
    update_initramfs_if_available
  else
    log "runtime-only mode enabled; persistent modprobe config will not be written"
  fi

  if [[ "$RELOAD_HID_APPLE" == "yes" ]]; then
    maybe_reload_hid_apple yes
  else
    apply_runtime_mapping || true
    if [[ "$RELOAD_HID_APPLE" == "auto" ]]; then
      maybe_reload_hid_apple auto
    fi
  fi

  apply_plasma_meta_launcher "$PLASMA_META_LAUNCHER"
  status
}

restore_action() {
  require_root

  if (( PERSIST )); then
    remove_modprobe_profile
    update_initramfs_if_available
  else
    log "runtime-only mode enabled; persistent modprobe config will be left as-is"
  fi

  if [[ "$RELOAD_HID_APPLE" == "yes" ]]; then
    maybe_reload_hid_apple yes
  else
    restore_runtime_mapping || true
    if [[ "$RELOAD_HID_APPLE" == "auto" ]]; then
      maybe_reload_hid_apple auto
    fi
  fi

  if [[ "$PLASMA_META_LAUNCHER" == "on" || "$PLASMA_META_LAUNCHER" == "auto" ]]; then
    disable_plasma_meta_launcher
  fi

  status
}

main() {
  local arg

  for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
      usage
      exit 0
    fi
  done

  for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == "--config" ]]; then
      local next_index=$((i + 1))
      [[ $next_index -le $# ]] || die "--config requires a path"
      read_config_file "${!next_index}"
      break
    fi
  done

  parse_args "$@"

  case "$ACTION" in
    apply)
      apply_action
      ;;
    restore)
      restore_action
      ;;
    status)
      status
      ;;
    *)
      die "unsupported action: $ACTION"
      ;;
  esac
}

main "$@"
