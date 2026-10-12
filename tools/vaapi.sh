#!/bin/bash
# SPDX-License-Identifier: 0BSD
#
# Hardware video decode for the CHUWI MiniBook X on Fedora.
#
# Fedora does not ship Intel's iHD media driver -- it lives in RPM Fusion
# because of codec patents -- so without this VA-API falls back to software.
# This enables RPM Fusion, installs intel-media-driver and libva-utils, and
# turns VA-API on in Firefox by writing user.js for every profile.
#
# Adapted from nfoulon-dev's minibook-fix scripts.
#
# Usage: sudo tools/vaapi.sh [--no-driver] [--no-firefox]
#        tools/vaapi.sh --check   exit 0 when everything is in place

set -euo pipefail

readonly REPO_FREE_URL="https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-%s.noarch.rpm"
readonly REPO_NONFREE_URL="https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-%s.noarch.rpm"
readonly DRIVER_PACKAGES=(intel-media-driver libva-utils)
readonly PREFS=(
  'user_pref("media.ffmpeg.vaapi.enabled", true);'
  'user_pref("media.hardware-video-decoding.enabled", true);'
)

WITH_DRIVER=1
WITH_FIREFOX=1
WITH_UPDATES=1

log() { echo "==> $*"; }
warn() { echo "Warning: $*" >&2; }
die() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: sudo $0 [--no-driver] [--no-firefox]
       $0 --check

  --no-driver    do not touch RPM Fusion or the media driver
  --no-firefox   do not write the Firefox preferences
  --no-update    do not refresh the packages, use what is installed
  --check        report whether everything is in place, change nothing
EOF
  exit 0
}

target_user() {
  echo "${SUDO_USER:-$(id -un)}"
}

target_home() {
  local user
  local home

  user="$(target_user)"
  home="$(getent passwd "${user}" | cut -d: -f6)"
  echo "${home:-/home/${user}}"
}

driver_installed() {
  rpm -q intel-media-driver >/dev/null 2>&1
}

firefox_profiles() {
  local base
  local path
  local home

  home="$(target_home)"
  base="${FIREFOX_PROFILES_DIR:-${home}/.mozilla/firefox}"
  if [[ ! -d "${base}" ]]; then
    return 0
  fi
  while IFS= read -r path; do
    if [[ -d "${base}/${path}" ]]; then
      echo "${base}/${path}"
    elif [[ -d "${path}" ]]; then
      echo "${path}"
    fi
  done < <(awk -F= '
    /^\[/ { in_profile = ($0 ~ /^\[Profile/); next }
    in_profile && /^Path=/ { sub(/^Path=/, ""); print }
  ' "${base}/profiles.ini" 2>/dev/null)
}

profile_has_prefs() {
  local profile="$1"
  local pref

  if [[ ! -f "${profile}/user.js" ]]; then
    return 1
  fi
  for pref in "${PREFS[@]}"; do
    if ! grep -qF -- "${pref}" "${profile}/user.js"; then
      return 1
    fi
  done
  return 0
}

prefs_configured() {
  local profile

  profile="$(firefox_profiles | head -1)"
  if [[ -z "${profile}" ]]; then
    return 0
  fi
  profile_has_prefs "${profile}"
}

show_check() {
  local status=0

  if driver_installed; then
    log "intel-media-driver is installed"
  else
    log "intel-media-driver is missing (RPM Fusion)"
    status=1
  fi
  if prefs_configured; then
    log "Firefox VA-API preferences are set"
  else
    log "Firefox VA-API preferences are missing"
    status=1
  fi
  exit "${status}"
}

enable_rpm_fusion() {
  local release

  release="$(rpm -E %fedora)"
  if rpm -q rpmfusion-free-release >/dev/null 2>&1 \
    && rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
    if [[ "${WITH_UPDATES}" -eq 0 ]]; then
      log "RPM Fusion is already enabled"
      return 0
    fi
    log "updating the RPM Fusion release packages"
    dnf install -y --refresh rpmfusion-free-release rpmfusion-nonfree-release
    return 0
  fi
  log "enabling RPM Fusion (needed for the Intel media driver)"
  dnf install -y \
    "$(printf "${REPO_FREE_URL}" "${release}")" \
    "$(printf "${REPO_NONFREE_URL}" "${release}")"
}

install_driver() {
  if [[ "${WITH_UPDATES}" -eq 0 ]] && driver_installed \
    && command -v vainfo >/dev/null; then
    log "the Intel media driver is already installed"
    return 0
  fi
  enable_rpm_fusion
  log "installing or updating ${DRIVER_PACKAGES[*]}"
  dnf install -y --refresh "${DRIVER_PACKAGES[@]}"
  log "verify with: vainfo"
}

write_profile_prefs() {
  local profile="$1"
  local user
  local pref
  local added=0

  if profile_has_prefs "${profile}"; then
    return 0
  fi
  user="$(target_user)"
  for pref in "${PREFS[@]}"; do
    if grep -qF -- "${pref%%:*}" "${profile}/user.js" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "${pref}" >>"${profile}/user.js"
    added=1
  done
  chown "${user}" "${profile}/user.js" 2>/dev/null || true
  if [[ "${added}" -eq 1 ]]; then
    log "enabled VA-API in ${profile}/user.js"
  fi
}

configure_firefox() {
  local profile
  local found=0

  while IFS= read -r profile; do
    found=1
    write_profile_prefs "${profile}"
  done < <(firefox_profiles)
  if [[ "${found}" -eq 0 ]]; then
    warn "no Firefox profile yet, start Firefox once and re-run to set the"
    warn "VA-API preferences"
    return 0
  fi
  if pgrep -x firefox >/dev/null 2>&1; then
    warn "Firefox is running, restart it to pick up the preferences"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-driver)
      WITH_DRIVER=0
      shift
      ;;
    --no-firefox)
      WITH_FIREFOX=0
      shift
      ;;
    --no-update)
      WITH_UPDATES=0
      shift
      ;;
    --check)
      show_check
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
  if [[ ${EUID} -ne 0 ]]; then
    die "installing the video decode stack needs root"
  fi
  if [[ "${WITH_DRIVER}" -eq 1 ]]; then
    install_driver
  fi
  if [[ "${WITH_FIREFOX}" -eq 1 ]]; then
    configure_firefox
  fi
}

main "$@"
