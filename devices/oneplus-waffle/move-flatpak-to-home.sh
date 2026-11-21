#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Move the system Flatpak data (/var/lib/flatpak: Fedora runtimes, Firefox;
# ~3.5 GB on 2026-11-21) off the 8 GiB fap_root onto /home (fap-home, the
# former userdata, ~447 GiB) and bind-mount it back. One-time migration for an
# already-installed phone; new installs get the same fstab line from
# installroot/etc/fstab.
#
# Run ON THE PHONE as root, one step at a time:
#   sudo ./move-flatpak-to-home.sh            check only (default), changes nothing
#   sudo ./move-flatpak-to-home.sh --apply    copy, verify, bind-mount; old copy kept
#   sudo ./move-flatpak-to-home.sh --remove-old   after checking apps still work:
#                                             delete the old copy, frees ~3.5 GB on /
#   sudo ./move-flatpak-to-home.sh --rollback undo (works until --remove-old;
#                                             after that it copies back from /home)
#
# Safety: no partition writes. Only /var/lib/flatpak, /etc/fstab and
# /home/.var-lib-flatpak are touched. If /home ever fails to mount, the bind is
# skipped (nofail): the phone boots, system Flatpak apps are just missing.
set -euo pipefail

# MFH_* overrides exist only for testing the script on a scratch tree.
SRC=${MFH_SRC:-/var/lib/flatpak}
DST=${MFH_DST:-/home/.var-lib-flatpak}
OLD=${MFH_OLD:-/var/lib/flatpak.pre-home}
FSTAB=${MFH_FSTAB:-/etc/fstab}
HOME_DIR=${MFH_HOME:-/home}
FSTAB_LINE="$DST  $SRC  none  bind,nofail,x-systemd.requires-mounts-for=$HOME_DIR  0 0"
MODE=${1:---check}

say() { printf '%s\n' "$*"; }
die() { printf 'move-flatpak-to-home: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
command -v rsync >/dev/null || die "rsync missing"
command -v flatpak >/dev/null || die "flatpak missing"

is_bound() { findmnt -n "$SRC" >/dev/null 2>&1; }

preflight() {
  if [ -z "${MFH_HOME:-}" ]; then
    [ "$(findmnt -no TARGET --source LABEL=fap-home 2>/dev/null | head -1)" = /home ] \
      || die "/home is not the fap-home partition (findmnt /home); refusing"
  fi
  if [ -n "$(flatpak ps --columns=application 2>/dev/null)" ]; then
    die "Flatpak apps are running ($(flatpak ps --columns=application | tr '\n' ' ')); close them first"
  fi
}

case "$MODE" in
--check)
  say "root:  $(df -h / | awk 'NR==2{print $4" free of "$2}')"
  say "home:  $(df -h "$HOME_DIR" | awk 'NR==2{print $4" free of "$2}')"
  say "size of $SRC: $(du -sh "$SRC" 2>/dev/null | cut -f1)"
  if is_bound; then say "state: already moved ($SRC is bind-mounted from $(findmnt -no SOURCE "$SRC"))"
  elif [ -d "$OLD" ]; then say "state: half-done? $OLD exists but $SRC is not mounted; see --rollback"
  else say "state: not moved"; fi
  grep -qF "$DST" "$FSTAB" && say "fstab: has the bind line" || say "fstab: no bind line yet"
  preflight
  say "checks passed; next: --apply"
  ;;
--apply)
  is_bound && die "already moved"
  [ -e "$OLD" ] && die "$OLD exists from an earlier attempt; --rollback first"
  preflight
  before=$(flatpak list --system --columns=application,branch | sort)
  need=$(du -sk "$SRC" | cut -f1)
  free=$(df -k --output=avail "$HOME_DIR" | tail -1)
  [ "$free" -gt $((need * 2)) ] || die "not enough space on $HOME_DIR"
  say "copying $SRC -> $DST (this takes a while)"
  mkdir -p "$DST"
  rsync -aHAX --numeric-ids --delete "$SRC/" "$DST/"
  say "verifying (checksums)"
  diffs=$(rsync -aHAXn --numeric-ids --checksum --itemize-changes --delete "$SRC/" "$DST/")
  [ -z "$diffs" ] || die "copy differs from source, stopping before any switch:
$diffs"
  mv "$SRC" "$OLD"
  install -d -m 0755 -o root -g root "$SRC"
  grep -qF "$DST" "$FSTAB" || printf '%s\n' "$FSTAB_LINE" >> "$FSTAB"
  systemctl daemon-reload
  # mount directly now; the fstab line does it at every boot
  mount --bind "$DST" "$SRC"
  is_bound || die "bind mount failed; run --rollback"
  after=$(flatpak list --system --columns=application,branch | sort)
  [ "$before" = "$after" ] || die "flatpak list differs after the move; run --rollback
before:
$before
after:
$after"
  say "done: $SRC is now on /home. Old copy kept in $OLD ($(du -sh "$OLD" | cut -f1) on /)."
  say "Check your Flatpak apps (e.g. Firefox), reboot once, then: $0 --remove-old"
  ;;
--remove-old)
  is_bound || die "$SRC is not bind-mounted; nothing to clean up safely"
  [ -d "$OLD" ] || die "no $OLD to remove"
  rm -rf --one-file-system "$OLD"
  say "removed $OLD; root now: $(df -h / | awk 'NR==2{print $4" free of "$2}')"
  ;;
--rollback)
  preflight
  if ! is_bound && [ ! -d "$OLD" ] && ! grep -qF "$DST" "$FSTAB"; then
    say "nothing to roll back: $SRC was never moved"
    exit 0
  fi
  if is_bound; then umount "$SRC"; fi
  sed -i "\\|^${DST}[[:space:]]|d" "$FSTAB"
  systemctl daemon-reload
  if [ -d "$OLD" ]; then
    rmdir "$SRC" 2>/dev/null || die "$SRC is not empty after unmount; inspect it"
    mv "$OLD" "$SRC"
  elif [ -d "$DST" ]; then
    say "old copy already removed: copying back from $DST"
    rsync -aHAX --numeric-ids --delete "$DST/" "$SRC/"
  else
    die "neither $OLD nor $DST exists; restore $SRC from a backup"
  fi
  say "rolled back: $SRC is on / again ($DST left in place; delete it yourself when sure)"
  ;;
*)
  sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
  ;;
esac
