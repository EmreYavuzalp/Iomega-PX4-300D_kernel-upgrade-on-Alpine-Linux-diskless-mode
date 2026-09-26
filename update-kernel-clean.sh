#!/bin/sh
# Wrapper around Alpine's update-kernel for this NAS (Atom D525, Intel GMA3150,
# no Nvidia/AMD GPU, wired Realtek NICs only, diskless boot from /media/usb).
#
# Stock update-kernel has two problems on this box:
#  1. A crash: the firmware-copy loop uses `[ -e "$f" ]` instead of `[ -f "$f" ]`,
#     so it chokes if a firmware "file" referenced by a module is actually a
#     directory (seen with ath11k/WCN6855/hw2.0/nfa765 in current linux-firmware).
#  2. It unconditionally bundles firmware for every GPU vendor the generic lts
#     kernel supports (nvidia GSP blobs alone were 100MB+) into both modloop
#     and initramfs, regardless of what hardware is actually present.
#
# This script re-applies both fixes to /usr/sbin/update-kernel if missing
# (needed again after any alpine-conf package upgrade replaces the file),
# then runs it with the right flags for this box:
#  -M          use the boot/<files> media layout (matches grub.cfg/syslinux.cfg)
#  -F ...      initramfs features, deliberately WITHOUT "kms" (no local
#              graphical console needed on a headless NAS; kms feature was
#              what pulled full GPU firmware into initramfs)
#
# Usage: ./update-kernel-clean.sh [big-scratch-dir]
#   big-scratch-dir defaults to /media/emre/750gb/tmp-update-kernel and is used
#   as TMPDIR, because the default /tmp is RAM-backed tmpfs and too small to
#   stage a full kernel+firmware build (needs ~1GB free).
# /media/emre/750gb is a disk inside our NAS, this script uses it as a temporary kernel files area. Change it accordingly to your setup.
set -e

UK=/usr/sbin/update-kernel
SCRATCH="${1:-/media/emre/750gb/tmp-update-kernel}"

if [ "$(id -u)" != 0 ]; then
	echo "Run as root (su -)" >&2
	exit 1
fi

patch_needed=0
grep -qF 'if ! [ -f "$f" ]; then' "$UK" || patch_needed=1
grep -qF 'rm -rf $ROOTFS/lib/firmware/nvidia' "$UK" || patch_needed=1

if [ "$patch_needed" = 1 ]; then
	echo "== Patching $UK =="
	cp "$UK" "$UK.orig.$(date +%Y%m%d%H%M%S)"

	# Fix 1: don't hand directories to `install -pD`
	if ! grep -qF 'if ! [ -f "$f" ]; then' "$UK"; then
		sed -i 's/if ! \[ -e "\$f" \]; then/if ! [ -f "$f" ]; then/' "$UK"
	fi
	if ! grep -qF '[ -f "$_file" ] && install -pD "$_file"' "$UK"; then
		sed -i 's|^\([[:space:]]*\)install -pD "\$_file" "\$MODLOOP/modules/firmware/\${_file#\*/lib/firmware/}"$|\1[ -f "$_file" ] \&\& install -pD "$_file" "$MODLOOP/modules/firmware/${_file#*/lib/firmware/}"|' "$UK"
	fi

	# Fix 2: drop firmware for GPU vendors this box doesn't have, right after
	# the rootfs package install, so neither modloop nor initramfs pick it up.
	if ! grep -qF 'rm -rf $ROOTFS/lib/firmware/nvidia' "$UK"; then
		sed -i '/^_apk add --no-scripts alpine-base \$PACKAGES$/a\
rm -rf $ROOTFS/lib/firmware/nvidia $ROOTFS/lib/firmware/amdgpu $ROOTFS/lib/firmware/radeon $ROOTFS/lib/firmware/xe' "$UK"
	fi

	sh -n "$UK" || { echo "Patched script has a syntax error, check $UK vs $UK.orig.*" >&2; exit 1; }
	echo "== Patch applied =="
else
	echo "== $UK already patched, skipping =="
fi

mkdir -p "$SCRATCH"
case "$(df -P "$SCRATCH" | awk 'NR==2{print $1}')" in
	tmpfs|rootfs|none|"")
		echo "$SCRATCH is on RAM (tmpfs), the data disk is not mounted. Aborting." >&2
		exit 1;;
esac

# Package cache for the kernel build root must NOT be /etc/apk/cache (that
# points at the 1GB boot flash; the firmware packages alone are ~600MB).
APKCACHE="$SCRATCH/apk-cache"
mkdir -p "$APKCACHE"

mount -o remount,rw /media/usb
avail=$(df -Pk /media/usb | awk 'NR==2{print $4}')
if [ "$avail" -lt 250000 ]; then
	echo "Only $((avail/1024))MB free on /media/usb, need ~250MB. Try: apk cache clean" >&2
	mount -o remount,ro /media/usb
	exit 1
fi

echo "== Running update-kernel (TMPDIR=$SCRATCH) =="
TMPDIR="$SCRATCH" update-kernel -v -M -c "$APKCACHE" \
	-F ata -F base -F cdrom -F ext4 -F keymap -F mmc -F nvme -F raid -F scsi -F usb -F virtio -F squashfs \
	/media/usb

echo "== Done. New boot files: =="
ls -la /media/usb/boot
df -h /media/usb
rm -rf "$APKCACHE"
mount -o remount,ro /media/usb
