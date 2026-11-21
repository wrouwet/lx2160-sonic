#!/bin/sh
# Build LX2160ARDB firmware and kernel from ~/lx2160-workspace/src.
# Usage: build-all.sh [step...]   steps: rcw uboot atf mcutils kernel fwimg
# No arguments builds everything in that order. Logs go to $W/logs/build-*.log.
set -eu

W=${W:-$HOME/lx2160-workspace}
S=$W/src
J=${J:-$(nproc)}
RCW_NAME=${RCW_NAME:-rcw_2000_700_2400_19_5_2}
RCW_BIN=$S/rcw/lx2160ardb_rev2/XGGFF_PP_HHHH_RR_19_5_2/$RCW_NAME.bin
export CROSS_COMPILE=${CROSS_COMPILE:-$W/toolchain/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-}

log() { echo "$W/logs/build-$1.log"; }

do_rcw() {
	make -C "$S/rcw/lx2160ardb_rev2" -j"$J" > "$(log rcw)" 2>&1
	ls -l "$RCW_BIN"
}

do_uboot() {
	make -C "$S/u-boot" lx2160ardb_tfa_defconfig > "$(log uboot)" 2>&1
	make -C "$S/u-boot" -j"$J" >> "$(log uboot)" 2>&1
	ls -l "$S/u-boot/u-boot.bin"
}

# SD build in build/, FlexSPI NOR build in build-nor/ (kept apart on purpose)
do_atf() {
	make -C "$S/atf" -j"$J" PLAT=lx2160ardb BOOT_MODE=sd \
		RCW="$RCW_BIN" BL33="$S/u-boot/u-boot.bin" pbl fip > "$(log atf-sd)" 2>&1
	make -C "$S/atf" -j"$J" BUILD_BASE=build-nor PLAT=lx2160ardb BOOT_MODE=flexspi_nor \
		RCW="$RCW_BIN" BL33="$S/u-boot/u-boot.bin" pbl fip > "$(log atf-nor)" 2>&1
	ls -l "$S"/atf/build*/lx2160ardb/release/*.pbl
}

do_mcutils() {
	make -C "$S/mc-utils/config" > "$(log mcutils)" 2>&1
	ls -l "$S"/mc-utils/config/lx2160a/LX2160A-RDB/*.dtb
}

# Only the RDB device tree: building all dtbs fails on unrelated vendors.
do_kernel() {
	make -C "$S/linux" ARCH=arm64 defconfig lsdk.config > "$(log kernel)" 2>&1
	(cd "$S/linux" && ARCH=arm64 scripts/kconfig/merge_config.sh -m -O . .config \
		"$W/scripts/kernel-docker.config" && make ARCH=arm64 olddefconfig) >> "$(log kernel)" 2>&1
	make -C "$S/linux" ARCH=arm64 -j"$J" Image modules \
		freescale/fsl-lx2160a-rdb.dtb >> "$(log kernel)" 2>&1
	ls -l "$S/linux/arch/arm64/boot/Image"
}

do_fwimg() {
	MODE=sd "$W/scripts/mk-fwimg.sh"
	MODE=nor "$W/scripts/mk-fwimg.sh"
}

[ $# -eq 0 ] && set -- rcw uboot atf mcutils kernel fwimg
for step; do
	echo "== $step"
	"do_$step"
done
