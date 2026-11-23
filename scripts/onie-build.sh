#!/bin/sh
# Build ONIE for the LX2160ARDB (machine nxp_lx2160ardb): upstream ONIE at
# ONIE_REF plus patches/onie/*.patch (also proposed upstream as
# opencomputeproject/onie#1143), in ONIE's Debian 9 build container.
# Works on x86_64 and aarch64 hosts with Docker. Unprivileged (docker group).
# Output: $W/onie/build/images/nxp_lx2160ardb-r0.itb (FIT image for NOR
# 0x1000000) and onie-updater-arm64-nxp_lx2160ardb-r0 (for onie-self-update).
# The first build compiles a cross toolchain: about 1 h on 16 cores.
set -eu

W=${W:-$HOME/lx2160-workspace}
ONIE_REF=${ONIE_REF:-ac03c31f}
J=${J:-$(nproc)}
O=$W/onie
IMG=onie-build-env:lx2160

[ -d "$O/.git" ] || git clone -q https://github.com/opencomputeproject/onie.git "$O"
for p in "$W"/patches/onie/*.patch; do
	if git -C "$O" apply --reverse --check "$p" 2>/dev/null; then
		continue
	fi
	git -C "$O" checkout -q "$ONIE_REF"
	git -C "$O" apply "$p"
	echo "patched: $(basename "$p")"
done

# The build user in the container is uid 1000; the source tree must be
# writable by it. A low open-files limit keeps Python 2 (close_fds) fast;
# crosstool-NG wants at least 2048.
docker build -q --ulimit nofile=4096:4096 -t "$IMG" "$O/contrib/build-env"
# image-updater builds the FIT image and the updater; this machine has no
# ONIE ROM image (U-Boot is not built by ONIE), so "all" would stop there.
docker run --rm --ulimit nofile=4096:4096 -v "$O:/home/build/src/onie" \
	-w /home/build/src/onie/build-config "$IMG" \
	make -j"$J" MACHINEROOT=../machine/nxp MACHINE=nxp_lx2160ardb image-updater
ls -l "$O/build/images/"
