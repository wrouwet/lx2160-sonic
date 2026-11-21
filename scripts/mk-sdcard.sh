#!/bin/sh
# Assemble a bootable LX2160ARDB SD card image, unprivileged:
#   0x0000000  MBR (partition table)
#   0x0001000  SD firmware (RCW/BL2, FIP, DDR FIP, MC, DPL, DPC) from mk-fwimg.sh
#   64 MiB     p1: ext4 root filesystem (Debian + kernel + /boot/extlinux)
# The NOR firmware image is copied to /boot/firmware/ so U-Boot can flash it.
set -eu

W=${W:-$HOME/lx2160-workspace}
S=$W/src
O=$W/out
ROOTFS_TAR=${ROOTFS_TAR:-$O/rootfs-trixie-arm64.tar}
ROOTFS_SIZE=${ROOTFS_SIZE:-3G}
OUT=${1:-$O/lx2160ardb-sdcard.img}
DISKID=0x1c216001
KDIR=$S/linux
DTB=fsl-lx2160a-rdb.dtb
CROSS_COMPILE=${CROSS_COMPILE:-$W/toolchain/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-}

T=$O/sdcard-staging
rm -rf "$T"
mkdir -p "$T/root/boot/extlinux" "$T/root/boot/firmware"

# Kernel, DTB and modules
KREL=$(make -s -C "$KDIR" ARCH=arm64 kernelrelease)
cp "$KDIR/arch/arm64/boot/Image" "$T/root/boot/Image"
cp "$KDIR/arch/arm64/boot/dts/freescale/$DTB" "$T/root/boot/$DTB"
make -s -C "$KDIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
	INSTALL_MOD_PATH="$T/root" INSTALL_MOD_STRIP=1 modules_install
rm -f "$T/root/lib/modules/$KREL/build" "$T/root/lib/modules/$KREL/source"
# Debian trixie has a merged /usr: /lib is a symlink, so modules live in /usr/lib
mkdir -p "$T/root/usr"
mv "$T/root/lib" "$T/root/usr/lib"

# Boot menu for U-Boot distro boot
cat > "$T/root/boot/extlinux/extlinux.conf" <<EOF
default debian
timeout 3
label debian
	menu label Debian 13 (Linux $KREL)
	kernel /boot/Image
	fdt /boot/$DTB
	append console=ttyAMA0,115200 earlycon root=PARTUUID=${DISKID#0x}-01 rootwait rw
EOF

cp "$O/lx2160ardb-nor-fw.img" "$O/lx2160ardb-sd-fw.img" "$T/root/boot/firmware/"
(cd "$T/root/boot/firmware" && sha256sum *.img > SHA256SUMS)

# rootfs tar + our files (owned by root) -> ext4. Appended directory entries
# (./, ./usr, ./boot) override the rootfs ones, so keep them at 755.
chmod -R u=rwX,go=rX "$T/root"
cp "$ROOTFS_TAR" "$T/combined.tar"
tar --owner=0 --group=0 -C "$T/root" -rf "$T/combined.tar" .
mkfs.ext4 -q -L rootfs -d "$T/combined.tar" "$T/rootfs.ext4" "$ROOTFS_SIZE"

# Disk image: firmware area + partition table + rootfs
rm -f "$OUT"
cp "$O/lx2160ardb-sd-fw.img" "$OUT"
truncate -s $((64 * 1024 * 1024)) "$OUT"
dd if="$T/rootfs.ext4" of="$OUT" bs=1M seek=64 conv=sparse,notrunc status=none
# conv=sparse skips the trailing zeros, so pad back to the full size before
# sfdisk sizes p1 to the end of the file
truncate -s $((64 * 1024 * 1024 + $(stat -c %s "$T/rootfs.ext4"))) "$OUT"
printf 'label: dos\nlabel-id: %s\nstart=131072, type=83, bootable\n' "$DISKID" |
	sfdisk -q "$OUT"

rm -rf "$T"
echo "kernel: $KREL"
sfdisk -l "$OUT" | tail -2
ls -lsh "$OUT"
