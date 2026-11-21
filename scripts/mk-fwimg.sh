#!/bin/sh
# Assemble an LX2160ARDB firmware image (raw, no partition table).
# MODE=sd (default) or MODE=nor (FlexSPI NOR, written from U-Boot with sf update).
# Offsets match TF-A (PLAT_FIP_OFFSET, PLAT_DDR_FIP_OFFSET) and U-Boot
# SD_MC_INIT_CMD / XSPI_MC_INIT_CMD; only the PBL offset differs between modes.
set -eu

W=${W:-$HOME/lx2160-workspace}
S=$W/src
RCW=${RCW:-rcw_2000_700_2400_19_5_2}
MODE=${MODE:-sd}

case $MODE in
sd)
	B=$S/atf/build/lx2160ardb/release
	PBL=$B/bl2_sd.pbl
	PBL_OFF=0x001000
	;;
nor)
	B=$S/atf/build-nor/lx2160ardb/release
	PBL=$B/bl2_flexspi_nor.pbl
	PBL_OFF=0x000000
	;;
*)
	echo "error: MODE must be sd or nor" >&2
	exit 1
	;;
esac

OUT=${1:-$W/out/lx2160ardb-$MODE-fw.img}
FIP=$B/fip.bin
FIPDDR=$S/ddr-phy-binary/lx2160a/fip_ddr.bin
MC=$S/qoriq-mc-binary/lx216xa/mc_lx2160a_10.40.0.itb
# DPL_NAME=sonic (default): firmware/dpl, DPNIs on dpmac17/18/2/3/4 (build-all.sh dpl)
# DPL_NAME=nxp: NXP's dpl-eth.19, DPNIs on dpmac17 and dpmac2 only
case ${DPL_NAME:-sonic} in
sonic) DPL=$W/out/dpl-lx2160ardb-sonic.dtb ;;
nxp) DPL=$S/mc-utils/config/lx2160a/LX2160A-RDB/dpl-eth.19.dtb ;;
*) echo "error: DPL_NAME must be sonic or nxp" >&2; exit 1 ;;
esac
DPC=$S/mc-utils/config/lx2160a/LX2160A-RDB/dpc-usxgmii.dtb

# name file offset max_size (bytes)
put() {
	sz=$(stat -c %s "$2")
	if [ "$sz" -gt $(($4)) ]; then
		echo "error: $1 is $sz bytes, exceeds slot of $(($4))" >&2
		exit 1
	fi
	dd if="$2" of="$OUT" bs=512 seek=$(($3 / 512)) conv=notrunc status=none
	printf '  %-8s @ 0x%07x  %8d bytes  %s\n' "$1" $(($3)) "$sz" "$2"
}

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
truncate -s 16M "$OUT"

echo "MODE: $MODE  RCW: $RCW"
put pbl    "$PBL"    $PBL_OFF 0x0ff000
put fip    "$FIP"    0x100000 0x400000   # U-Boot env lives at 0x500000
put fipddr "$FIPDDR" 0x800000 0x200000
put mc     "$MC"     0xa00000 0x240000
put dpl    "$DPL"    0xd00000 0x100000
put dpc    "$DPC"    0xe00000 0x100000

sha256sum "$OUT"
