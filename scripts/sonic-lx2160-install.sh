#!/bin/sh
# Install a SONiC LX2160ARDB image by hand, the way SONiC's installer lays out
# an image directory, until the board has a real installer.
#   - unpacks the .bin payload (fs.zip) into <mnt>/image-<version>/
#   - extracts dockerfs.tar.gz into image-<version>/docker and platform.tar.gz
#     into image-<version>/platform
#   - writes <mnt>/machine.conf (onie_platform=arm64-nxp_lx2160ardb-r0) if absent
#   - with --uboot-env: puts the image in U-Boot slot 1 with the image's own
#     installer hooks (platform.conf: lx2160_uboot_env), booted on the next
#     boot only (--uboot-env=once, the default) or always (--uboot-env=default);
#     a plain reset then returns to the previous default (Debian at first).
#     Needs fw_setenv (libubootenv-tool) and a saved U-Boot environment.
#   - otherwise prints the U-Boot commands to boot it by hand
# Non-destructive: only adds a directory and machine.conf on an existing ext4
# partition; other image-* directories and files are left alone.
# Run on the board as root:
#   sonic-lx2160-install.sh [--uboot-env[=once|default]] <sonic-nxp-lx2160-arm64.bin> [mountpoint]
set -eu

ENV_MODE=""
case "${1:-}" in
--uboot-env | --uboot-env=once) ENV_MODE=once; shift ;;
--uboot-env=default) ENV_MODE=default; shift ;;
esac
BIN=${1:?usage: sonic-lx2160-install.sh [--uboot-env[=once|default]] <sonic-*.bin> [mountpoint]}
MNT=${2:-/srv/build}
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
DEV=$(findmnt -n -o SOURCE --target "$MNT")
UUID=$(blkid -s UUID -o value "$DEV")
[ -n "$UUID" ] || { echo "no filesystem UUID for $MNT ($DEV)" >&2; exit 1; }
[ "$(findmnt -n -o TARGET --target "$MNT")" = "$MNT" ] ||
	{ echo "$MNT must be the root of its partition" >&2; exit 1; }

TMP=$(mktemp -d "$MNT/.sonic-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# .bin = shell archive; the tar payload follows the exit_marker line
sed -e '1,/^exit_marker$/d' "$BIN" | tar -xf - -C "$TMP"
INST=$(dirname "$(find "$TMP" -name fs.zip | head -1)")
[ -f "$INST/fs.zip" ] || { echo "fs.zip not found in $BIN" >&2; exit 1; }
VER=$(sed -n 's/^image_version="\(.*\)"$/\1/p' "$INST/install.sh" | head -1)
[ -n "$VER" ] || { echo "image_version not found in installer" >&2; exit 1; }
IMG=image-$VER

echo "Installing SONiC $VER to $MNT/$IMG ($DEV, UUID=$UUID)"
rm -rf "${MNT:?}/$IMG"
mkdir -p "$MNT/$IMG/docker" "$MNT/$IMG/platform"
unzip -q -o "$INST/fs.zip" -x dockerfs.tar.gz platform.tar.gz -d "$MNT/$IMG"
unzip -op "$INST/fs.zip" dockerfs.tar.gz | tar -xz --numeric-owner -f - -C "$MNT/$IMG/docker"
unzip -op "$INST/fs.zip" platform.tar.gz | tar -xz --numeric-owner -f - -C "$MNT/$IMG/platform"

if [ ! -f "$MNT/machine.conf" ]; then
	cat > "$MNT/machine.conf" <<EOF
onie_platform=arm64-nxp_lx2160ardb-r0
onie_machine=nxp_lx2160ardb
onie_arch=arm64
onie_switch_asic=vs
EOF
fi

if [ -n "$ENV_MODE" ]; then
	command -v fw_setenv >/dev/null || { echo "fw_setenv missing: apt install libubootenv-tool" >&2; exit 1; }
	PLAT=$(find "$TMP" -path '*/platforms/arm64-nxp_lx2160ardb-r0' | head -1)
	[ -n "$PLAT" ] && . "$PLAT"
	install_env=lx2160-linux
	. "$INST/platform.conf"
	lx2160_uboot_env "$MNT" "$IMG" "SONiC-OS-$VER" "$ENV_MODE"
	echo
	echo "U-Boot environment updated: slot 1 = SONiC-OS-$VER ($ENV_MODE)."
	fw_printenv sonic_version_1 sonic_version_2 boot_next boot_once 2>/dev/null || true
	exit 0
fi

FIT=$(ls "$MNT/$IMG"/boot/sonic_*.fit 2>/dev/null | head -1)
echo
echo "Image installed. At the U-Boot prompt (nothing is saved to the environment):"
# Stage the DPL well above the images: images built before patch 0004 load the
# kernel at 0x80200000, over U-Boot's usual DPL staging address 0x80d00000.
echo "  sf probe 0:0; sf read 0xb0000000 0xd00000 0x100000; fsl_mc lazyapply dpl 0xb0000000"
echo "  scsi scan"
echo "  setenv bootargs 'root=UUID=$UUID rw rootwait panic=1 console=ttyAMA0,115200 earlycon net.ifnames=0 loopfstype=squashfs loop=$IMG/fs.squashfs varlog_size=512'"
if [ -n "$FIT" ]; then
	echo "  ext4load scsi 0:1 0xa0000000 /$IMG/boot/$(basename "$FIT")"
	echo "  bootm 0xa0000000"
else
	echo "  (no FIT image found in $IMG/boot; load Image, initrd and DTB separately)"
fi
