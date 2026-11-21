#!/bin/bash
# Unattended arm64 SONiC image build (upstream sonic-buildimage) on an x86 host.
# Run as yourself (docker group), from a terminal, after `sudo -v`:
# Makefile.work starts its arm64 helper dockerd with sudo once per build
# environment (bookworm, then trixie, hours apart), so the sudo credential
# must stay cached for the whole build (see README, "Overnight SONiC build").
set -euo pipefail

W=${W:-$HOME/lx2160-workspace}
PLATFORM=${PLATFORM:-marvell-prestera}
ARCH=${ARCH:-arm64}
TARGET=target/sonic-$PLATFORM-$ARCH.bin
LOG=$W/logs/sonic-build-$(date +%Y%m%d-%H%M).log

export PATH=$HOME/.local/bin:$PATH
# Tests under qemu are slow and flaky; package parallelism 2 fits 14 GB RAM.
# Cap make -j per package too: 2 packages x nproc on the 16-core board OOMs.
export BUILD_SKIP_TEST=y SONIC_CONFIG_BUILD_JOBS=${SONIC_CONFIG_BUILD_JOBS:-2}
export SONIC_CONFIG_MAKE_JOBS=${SONIC_CONFIG_MAKE_JOBS:-$(( $(nproc) > 8 ? 8 : $(nproc) ))}

# Only a foreign-arch build (qemu) needs sudo, for Makefile.work's helper dockerd
case $(uname -m)-$ARCH in
aarch64-arm64 | armv7l-armhf | x86_64-amd64) NEED_SUDO=n ;;
*) NEED_SUDO=y ;;
esac

cd "$W/sonic-buildimage"

{
	echo "start:    $(date -Is)"
	echo "commit:   $(git log -1 --format='%h %cd %s')"
	echo "host:     $(uname -m), $(nproc) cpus, $(free -g | awk '/^Mem/{print $2}') GB"
	echo "target:   $TARGET  jobs=$SONIC_CONFIG_BUILD_JOBS make_jobs=$SONIC_CONFIG_MAKE_JOBS skip_test=$BUILD_SKIP_TEST"
	echo "disk:     $(df -h --output=avail / | tail -1) free"
	docker version --format 'docker:   {{.Server.Version}}'
	j2 --version | head -1
	if [ $NEED_SUDO = y ]; then
		sudo -n true && echo "sudo:     cached" || { echo "sudo:     NOT cached, run sudo -v first"; exit 1; }
	else
		echo "sudo:     not needed (native build)"
	fi
} 2>&1 | tee "$LOG"

ln -sfn "$(basename "$LOG")" "$W/logs/sonic-build-latest.log"

# Keep the laptop awake for the whole build
systemd-inhibit --what=sleep:idle --who=sonic-build --why="SONiC build" \
	bash -c "make configure PLATFORM=$PLATFORM PLATFORM_ARCH=$ARCH && make $TARGET" \
	>> "$LOG" 2>&1 && rc=0 || rc=$?

{
	echo "end:      $(date -Is)  rc=$rc"
	echo "disk:     $(df -h --output=avail / | tail -1) free"
	ls -l "$TARGET" 2>/dev/null || true
} | tee -a "$LOG"
exit $rc
