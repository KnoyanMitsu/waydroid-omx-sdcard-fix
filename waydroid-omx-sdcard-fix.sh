#!/usr/bin/env bash
# waydroid-omx-sdcard-fix.sh
#
# Workaround for an empty /sdcard in Waydroid (Android 13 images) caused by a
# vendor image that DECLARES the HIDL media.omx HAL in its VINTF manifest but
# does not SHIP the service binary. mediaserver then waits for IOmxStore
# forever, MediaProvider hangs in onCreate (MediaCodecList.getInstance), the
# FUSE session for /storage/emulated times out, and vold unmounts it.
#
# The fix is a vendor overlay containing a copy of the manifest with the
# android.hardware.media.omx <hal> block removed, so the lookup fails fast and
# Codec2 (media.swcodec) is used instead.
#
# Usage: waydroid-omx-sdcard-fix.sh {status|apply|revert|verify} [--restart]
set -eu

WD_DIR="${WD_DIR:-/var/lib/waydroid}"
OVERLAY_DIR="$WD_DIR/overlay/vendor/etc/vintf"
OVERLAY_MANIFEST="$OVERLAY_DIR/manifest.xml"
ROOTFS_MANIFEST="${MANIFEST_SRC:-$WD_DIR/rootfs/vendor/etc/vintf/manifest.xml}"
BACKUP="$WD_DIR/vendor-manifest.orig.xml"   # kept OUTSIDE the overlay on purpose

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "run as root (sudo not found)"
    exec sudo -E "$0" "$@"
  fi
}

# Read a manifest on stdin, drop every <hal> block that declares media.omx.
# Portable awk (works with busybox awk).
strip_omx() {
  awk '
    /<hal[ >]/ { inhal = 1; buf = "" }
    inhal {
      buf = buf $0 "\n"
      if ($0 ~ /<\/hal>/) {
        inhal = 0
        if (buf !~ /<name>android\.hardware\.media\.omx<\/name>/) printf "%s", buf
        buf = ""
      }
      next
    }
    { print }
    END { if (inhal) printf "%s", buf }
  '
}

count_omx() { grep -c 'android\.hardware\.media\.omx' "$1" 2>/dev/null || true; }

omx_binary_present() {
  for d in "$WD_DIR/rootfs/vendor/bin/hw" "$WD_DIR/rootfs/system/bin/hw"; do
    [ -d "$d" ] && ls "$d" 2>/dev/null | grep -qi 'media.omx' && return 0
  done
  return 1
}

restart_container() {
  say "Restarting Waydroid container ..."
  if [ -n "${SUDO_USER:-}" ]; then sudo -u "$SUDO_USER" waydroid session stop 2>/dev/null || true
  else waydroid session stop 2>/dev/null || true; fi
  if command -v systemctl >/dev/null 2>&1 && systemctl cat waydroid-container >/dev/null 2>&1; then
    systemctl restart waydroid-container
  elif command -v rc-service >/dev/null 2>&1 && [ -e /etc/init.d/waydroid-container ]; then
    rc-service waydroid-container restart
  else
    waydroid container stop 2>/dev/null || true
    waydroid container start
  fi
  say "Done. Now start the session as your normal user:  waydroid session start"
}

cmd_status() {
  say "Waydroid dir:       $WD_DIR"
  if [ -s "$OVERLAY_MANIFEST" ]; then
    say "Overlay manifest:   PRESENT ($OVERLAY_MANIFEST)"
    say "  omx entries in overlay: $(count_omx "$OVERLAY_MANIFEST")"
  else
    say "Overlay manifest:   absent"
  fi
  if [ -s "$ROOTFS_MANIFEST" ]; then
    say "Manifest seen by container: $(count_omx "$ROOTFS_MANIFEST") media.omx entries"
  else
    say "Manifest seen by container: unreadable (is the container running?)"
  fi
  if omx_binary_present; then say "OMX HAL binary in image: present (workaround probably NOT needed)"
  else say "OMX HAL binary in image: not found"; fi
}

cmd_apply() {
  [ -s "$OVERLAY_MANIFEST" ] && { say "Overlay already present: $OVERLAY_MANIFEST (run 'revert' first to redo it)"; return 0; }
  [ -s "$ROOTFS_MANIFEST" ] || die "cannot read $ROOTFS_MANIFEST - start the container first (waydroid session start)"
  [ "$(count_omx "$ROOTFS_MANIFEST")" -gt 0 ] || die "manifest does not declare media.omx; this workaround does not apply"
  if omx_binary_present; then
    die "an OMX HAL binary exists in the image; removing the declaration would hide a working HAL. Aborting."
  fi

  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  strip_omx < "$ROOTFS_MANIFEST" > "$tmp"
  [ -s "$tmp" ] || die "result is empty, aborting"
  grep -q '<manifest' "$tmp" || die "result lost the <manifest> root tag, aborting"
  [ "$(count_omx "$tmp")" -eq 0 ] || die "media.omx still present after stripping, aborting"

  cp -a "$ROOTFS_MANIFEST" "$BACKUP"
  mkdir -p "$OVERLAY_DIR"
  cp "$tmp" "$OVERLAY_MANIFEST"
  chmod 644 "$OVERLAY_MANIFEST"
  say "Overlay written: $OVERLAY_MANIFEST"
  say "Original manifest saved: $BACKUP"
  say "NOTE: the overlay replaces the whole vendor manifest. After a Waydroid image"
  say "      upgrade, diff against $BACKUP or run 'revert' to see if it is still needed."
  if [ "${1:-}" = "--restart" ]; then restart_container
  else say "Restart the container for it to take effect (or re-run with --restart)."; fi
}

cmd_revert() {
  if [ -e "$OVERLAY_MANIFEST" ]; then
    rm -f "$OVERLAY_MANIFEST"
    rmdir -p "$OVERLAY_DIR" 2>/dev/null || true     # remove now-empty dirs
    mkdir -p "$WD_DIR/overlay/vendor"               # keep the dir Waydroid expects
    say "Overlay removed."
  else
    say "No overlay to remove."
  fi
  if [ "${1:-}" = "--restart" ]; then restart_container
  else say "Restart the container for it to take effect (or re-run with --restart)."; fi
}

cmd_verify() {
  command -v waydroid >/dev/null 2>&1 || die "waydroid not found"
  n="$(waydroid shell -- grep -c media.omx /vendor/etc/vintf/manifest.xml 2>/dev/null | tr -d '\r' || true)"
  say "media.omx entries in the container's manifest: ${n:-?}   (0 = overlay active)"
  m="$(waydroid shell -- sh -c 'mount | grep -c " /storage/emulated "' 2>/dev/null | tr -d '\r' || true)"
  say "FUSE mounts on /storage/emulated:               ${m:-?}   (>=1 = mounted)"
  say "/sdcard contents:"
  waydroid shell -- ls /sdcard 2>&1 | sed 's/^/  /'
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  status|apply|revert|verify) need_root "$cmd" "$@"
    case "$cmd" in
      status) cmd_status ;;
      apply)  cmd_apply "${1:-}" ;;
      revert) cmd_revert "${1:-}" ;;
      verify) cmd_verify ;;
    esac ;;
  -h|--help|help) usage 0 ;;
  *) usage 1 ;;
esac
