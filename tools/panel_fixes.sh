#!/bin/bash
# SPDX-License-Identifier: 0BSD
#
# Panel fixes for the CHUWI MiniBook X on Fedora.
#
# The panel is a 1200x1920 DSI panel that the BIOS drives at 50 Hz, mounted
# rotated 270 degrees. This raises its refresh rate by patching the Video BIOS
# Table (loaded early via i915.vbt_firmware=vbt, no firmware flash involved) and
# tells i915 the panel orientation, so Plymouth, GDM, GNOME and the VT consoles
# come up upright.
#
# The procedure is the one worked out on this machine under Fedora 44, on top
# of the VBT patcher from fstanis/chuwi-minibook (vendored next to this script).
#
# Usage: sudo tools/panel_fixes.sh [--hz N] [--keep-grub-menu]
#        tools/panel_fixes.sh --check   exit 0 when already configured
#        sudo tools/panel_fixes.sh --revert

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PATCHER="${SCRIPT_DIR}/vbt_patch.py"

readonly VBT_DEST=/lib/firmware/vbt
readonly DRACUT_CONF=/etc/dracut.conf.d/minibook-vbt.conf
readonly GRUB=/etc/default/grub
readonly BACKUPS=/root/chuwi-display-backups
readonly BUNDLED_VBT="${SCRIPT_DIR}/../assets/vbt"
PANEL_HZ="${PANEL_HZ:-90}"
PANEL_CONN="${PANEL_CONN:-DSI-1}"
PANEL_ORIENTATION="${PANEL_ORIENTATION:-right_side_up}"
FBCON_ROTATE="${FBCON_ROTATE:-1}"
readonly PANEL_HZ PANEL_CONN PANEL_ORIENTATION FBCON_ROTATE
readonly PANEL_ARGS=(
  "i915.vbt_firmware=vbt"
  "video=${PANEL_CONN}:panel_orientation=${PANEL_ORIENTATION}"
  "fbcon=rotate:${FBCON_ROTATE}"
)
KEEP_GRUB_MENU=0
MODE=apply

log() { echo "==> $*"; }
warn() { echo "Warning: $*" >&2; }
die() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: sudo $0 [--hz N] [--keep-grub-menu]
       $0 --check
       sudo $0 --revert

  --hz N             refresh rate to patch into the VBT (default ${PANEL_HZ})
                     PANEL_CONN, PANEL_ORIENTATION and FBCON_ROTATE override the
                     connector, rotation direction and console rotation
                     (defaults ${PANEL_CONN}, ${PANEL_ORIENTATION}, ${FBCON_ROTATE})
  --keep-grub-menu   do not hide the boot menu (its text cannot be rotated)
  --check            report whether the fixes are configured, change nothing
  --revert           undo everything this script applied
EOF
  exit 0
}

args_string() {
  local joined="${PANEL_ARGS[*]}"

  echo "${joined}"
}

target_home() {
  local user
  local home

  user="${SUDO_USER:-$(id -un)}"
  home="$(getent passwd "${user}" | cut -d: -f6)"
  echo "${home:-/home/${user}}"
}

args_configured() {
  local arg

  for arg in "${PANEL_ARGS[@]}"; do
    if grep -q -- "${arg}" /proc/cmdline; then
      continue
    fi
    if [[ -r "${GRUB}" ]] && grep -q -- "${arg}" "${GRUB}"; then
      continue
    fi
    return 1
  done
  return 0
}

show_check() {
  if args_configured && [[ -f "${VBT_DEST}" ]]; then
    log "panel fixes are configured"
    exit 0
  fi
  log "panel fixes are not configured yet"
  exit 1
}

locate_vbt() {
  local candidate

  for candidate in /sys/kernel/debug/dri/*/i915_vbt; do
    if [[ -f "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

ensure_debugfs() {
  if mountpoint -q /sys/kernel/debug; then
    return
  fi
  log "mounting debugfs to read the current VBT"
  mount -t debugfs none /sys/kernel/debug
}

backup_files() {
  local stamp
  local target
  local destination

  stamp="$(date +%Y%m%d-%H%M%S)"
  for target in "${GRUB}" "$(target_home)/.config/monitors.xml"; do
    if [[ ! -f "${target}" ]]; then
      continue
    fi
    destination="${BACKUPS}/${stamp}/$(dirname "${target}" | tr '/' '_')"
    mkdir -p "${destination}"
    cp -a "${target}" "${destination}/"
  done
  log "backups written to ${BACKUPS}/${stamp}"
}

patch_vbt() {
  local source
  local scratch

  if ! source="$(locate_vbt)"; then
    if [[ ! -f "${BUNDLED_VBT}" ]]; then
      return 1
    fi
    warn "cannot read the running VBT, using the copy bundled in this repo"
    install -m 644 "${BUNDLED_VBT}" "${VBT_DEST}"
    log "installed the bundled VBT to ${VBT_DEST}"
    return 0
  fi
  scratch="$(mktemp)"
  cat "${source}" >"${scratch}"
  log "patching the panel VBT to ${PANEL_HZ} Hz"
  if ! python3 "${PATCHER}" "${scratch}" --hz "${PANEL_HZ}" "${VBT_DEST}"; then
    rm -f "${scratch}"
    return 1
  fi
  rm -f "${scratch}"
  chmod 644 "${VBT_DEST}"
}

install_dracut_items() {
  log "bundling the patched VBT into the initramfs"
  mkdir -p /etc/dracut.conf.d
  printf 'install_items+=" %s "\n' "${VBT_DEST}" >"${DRACUT_CONF}"
}

add_kernel_args() {
  log "adding kernel arguments: $(args_string)"
  grubby --update-kernel=ALL --args="$(args_string)"
}

remove_kernel_args() {
  log "removing kernel arguments: $(args_string)"
  grubby --update-kernel=ALL --remove-args="$(args_string)" || true
}

persist_grub_args() {
  local current
  local merged
  local arg

  [[ -f "${GRUB}" ]] || return 0
  current="$(sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/\1/p' "${GRUB}" | head -1)"
  merged="${current}"
  for arg in "${PANEL_ARGS[@]}"; do
    if [[ " ${merged} " == *" ${arg} "* ]]; then
      continue
    fi
    merged="${merged:+${merged} }${arg}"
  done
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${merged}\"|" "${GRUB}"
}

strip_grub_args() {
  local current
  local kept
  local arg

  [[ -f "${GRUB}" ]] || return 0
  current="$(sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/\1/p' "${GRUB}" | head -1)"
  kept=""
  for arg in ${current}; do
    if [[ " $(args_string) " == *" ${arg} "* ]]; then
      continue
    fi
    kept="${kept:+${kept} }${arg}"
  done
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${kept}\"|" "${GRUB}"
}

set_grub_var() {
  local name="$1"
  local value="$2"

  if grep -q "^${name}=" "${GRUB}"; then
    sed -i "s|^${name}=.*|${name}=\"${value}\"|" "${GRUB}"
  else
    printf '%s="%s"\n' "${name}" "${value}" >>"${GRUB}"
  fi
}

hide_grub_menu() {
  log "hiding the boot menu, its text cannot be rotated"
  set_grub_var GRUB_TIMEOUT 0
  set_grub_var GRUB_TIMEOUT_STYLE hidden
}

restore_grub_menu() {
  [[ -f "${GRUB}" ]] || return 0
  log "restoring the boot menu"
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "${GRUB}"
  sed -i '/^GRUB_TIMEOUT_STYLE=/d' "${GRUB}"
}

reset_monitors_rotation() {
  local monitors

  monitors="$(target_home)/.config/monitors.xml"
  if [[ ! -f "${monitors}" ]]; then
    return 0
  fi
  log "resetting a manual display rotation in ${monitors}"
  sed -i -E 's#<(rotation)>(right|left|upside_down)</\1>#<\1>normal</\1>#g' \
    "${monitors}"
}

restore_monitors_rotation() {
  local monitors
  local latest
  local saved

  monitors="$(target_home)/.config/monitors.xml"
  latest="$(ls -1dt "${BACKUPS}"/*/ 2>/dev/null | head -1)"
  if [[ -z "${latest}" || ! -d "$(dirname "${monitors}")" ]]; then
    return 0
  fi
  saved="$(find "${latest}" -name monitors.xml 2>/dev/null | head -1)"
  if [[ -z "${saved}" ]]; then
    return 0
  fi
  log "restoring ${monitors} from ${saved}"
  cp -a "${saved}" "${monitors}"
}

rebuild_boot() {
  log "rebuilding the boot configuration and initramfs"
  grub2-mkconfig -o /boot/grub2/grub.cfg
  dracut -f
}

have_tools() {
  local tool

  for tool in grubby dracut grub2-mkconfig mountpoint; do
    if ! command -v "${tool}" >/dev/null; then
      warn "${tool} is missing, skipping the panel fixes"
      return 1
    fi
  done
  return 0
}

apply_panel_fixes() {
  if args_configured && [[ -f "${VBT_DEST}" ]]; then
    log "panel fixes already applied, nothing to do"
    return 0
  fi
  if [[ ${EUID} -ne 0 ]]; then
    die "the panel fixes need root"
  fi
  if ! have_tools; then
    return 0
  fi
  backup_files
  ensure_debugfs
  if ! patch_vbt; then
    warn "cannot read or patch the firmware VBT, skipping the panel fixes"
    return 0
  fi
  install_dracut_items
  add_kernel_args
  persist_grub_args
  if [[ "${KEEP_GRUB_MENU}" -eq 0 ]]; then
    hide_grub_menu
  fi
  reset_monitors_rotation
  rebuild_boot
  log "the panel fixes take effect after a reboot"
}

revert_panel_fixes() {
  if [[ ${EUID} -ne 0 ]]; then
    die "reverting the panel fixes needs root"
  fi
  remove_kernel_args
  strip_grub_args
  log "removing the patched VBT"
  rm -f "${VBT_DEST}" "${DRACUT_CONF}"
  restore_grub_menu
  restore_monitors_rotation
  rebuild_boot
  log "the panel is back to stock after a reboot"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --hz)
      if [[ $# -lt 2 ]]; then
        die "--hz needs a value"
      fi
      PANEL_HZ="$2"
      shift 2
      ;;
    --keep-grub-menu)
      KEEP_GRUB_MENU=1
      shift
      ;;
    --check)
      MODE=check
      shift
      ;;
    --revert)
      MODE=revert
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      die "unknown option: $1"
      ;;
    esac
  done
}

main() {
  parse_args "$@"
  case "${MODE}" in
  check)
    show_check
    ;;
  revert)
    revert_panel_fixes
    ;;
  apply)
    apply_panel_fixes
    ;;
  esac
}

main "$@"
