#!/bin/sh
# Recreate ~/lx2160-workspace sources and toolchain on a new machine.
# Unprivileged. Host packages needed first (see HANDOFF.md, "Host setup").
set -eu

W=${W:-$HOME/lx2160-workspace}
TAG=${TAG:-lf-6.18.37-2.1.0}
TC=arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu
TC_SHA256=ddeaff1ea60d4135acba271b0143d9f5add02b68ab9e9be39672d1965c12e82f

mkdir -p "$W/src" "$W/toolchain/dl" "$W/out" "$W/logs"

# NXP Layerscape BSP sources, all at the same release tag
for r in rcw atf u-boot linux ddr-phy-binary qoriq-mc-binary mc-utils; do
	if [ -d "$W/src/$r/.git" ]; then
		echo "src/$r exists, skipping"
	else
		git clone -q --depth 1 -b "$TAG" "https://github.com/nxp-qoriq/$r.git" "$W/src/$r"
	fi
	printf '%-16s %s\n' "$r" "$(git -C "$W/src/$r" rev-parse --short=12 HEAD)"
done
(cd "$W/src/qoriq-mc-binary" && sha256sum -c lx216xa/*.sha256sum)

# Arm GNU toolchain, checksum-verified
if [ ! -x "$W/toolchain/$TC/bin/aarch64-none-linux-gnu-gcc" ]; then
	f=$TC.tar.xz
	curl -sSfL -o "$W/toolchain/dl/$f" \
		"https://developer.arm.com/-/media/Files/downloads/gnu/14.3.rel1/binrel/$f"
	echo "$TC_SHA256  $W/toolchain/dl/$f" | sha256sum -c
	tar -C "$W/toolchain" -xf "$W/toolchain/dl/$f"
fi
"$W/toolchain/$TC/bin/aarch64-none-linux-gnu-gcc" --version | head -1
