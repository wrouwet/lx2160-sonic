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
# Size make -j per package by memory, not cores: swss's p4orch test objects
# need ~2 GB per cc1plus, and 2 packages x 8 jobs on the 13 GB board got
# cc1plus OOM-killed. Allow one compiler per 2 GB, split over the packages.
export BUILD_SKIP_TEST=y SONIC_CONFIG_BUILD_JOBS=${SONIC_CONFIG_BUILD_JOBS:-2}
mem_gb=$(awk '/^MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
slots=$(( mem_gb / 2 < $(nproc) ? mem_gb / 2 : $(nproc) ))
mj=$(( slots / SONIC_CONFIG_BUILD_JOBS ))
export SONIC_CONFIG_MAKE_JOBS=${SONIC_CONFIG_MAKE_JOBS:-$(( mj < 1 ? 1 : mj ))}

# Only a foreign-arch build (qemu) needs sudo, for Makefile.work's helper dockerd
case $(uname -m)-$ARCH in
aarch64-arm64 | armv7l-armhf | x86_64-amd64) NEED_SUDO=n ;;
*) NEED_SUDO=y ;;
esac

# Makefile.work's DOCKER_MULTIARCH_CHECK re-registers binfmt with the 3-year-old
# multiarch/qemu-user-static (qemu 7.2), under which py3compile crashes
# (BrokenPipeError) while the arm64 slave container installs packages.
# Keep the host's qemu-user-binfmt (Ubuntu 26.04: static qemu 10.2, flags OPF).
MAKE_EXTRA=""
if [ $NEED_SUDO = n ]; then
	# Build SONiC's dockers with the host dockerd instead of a dockerd inside
	# the slave container (DinD). The inner dockerd uses iptables-legacy, which
	# needs NETFILTER_XTABLES_LEGACY; the LX2160A's kernel doesn't have it.
	export SONIC_CONFIG_USE_NATIVE_DOCKERD_FOR_BUILD=${SONIC_CONFIG_USE_NATIVE_DOCKERD_FOR_BUILD:-y}
else
	# qemu builds mount the multiarch dockerd's data root on /var/lib/docker;
	# with overlay2 Makefile.work mounts DOCKER_ROOT there too ("Duplicate
	# mount point"). Upstream CI uses vfs for qemu builds for the same reason.
	export SONIC_SLAVE_DOCKER_DRIVER=${SONIC_SLAVE_DOCKER_DRIVER:-vfs}
	MAKE_EXTRA="DOCKER_MULTIARCH_CHECK=true"
	# It also needs the C (credentials) flag, or setuid arm64 binaries such as
	# sudo inside the slave fail ("effective uid is not 0"). Ubuntu registers
	# POF; host/binfmt.d/qemu-aarch64.conf is the same line with OCPF.
	B=/proc/sys/fs/binfmt_misc/qemu-aarch64
	grep -qx "interpreter /usr/bin/qemu-aarch64" $B 2>/dev/null ||
		{ echo "binfmt qemu-aarch64 is not the host's qemu; see README" >&2; exit 1; }
	grep -q "^flags: .*C" $B ||
		{ echo "binfmt qemu-aarch64 lacks the C flag; install host/binfmt.d/qemu-aarch64.conf (README)" >&2; exit 1; }
fi

cd "$W/sonic-buildimage"

# Local fixes to sonic-buildimage (patches/sonic-buildimage/*.patch), applied
# once: skipped when they already apply in reverse.
for p in "$W"/patches/sonic-buildimage/*.patch; do
	[ -e "$p" ] || continue
	if git apply --reverse --check "$p" 2>/dev/null; then
		continue
	fi
	git apply "$p" && echo "patched:  $(basename "$p")"
done

{
	echo "start:    $(date -Is)"
	echo "commit:   $(git log -1 --format='%h %cd %s')"
	echo "host:     $(uname -m), $(nproc) cpus, $(free -g | awk '/^Mem/{print $2}') GB"
	echo "target:   $TARGET  jobs=$SONIC_CONFIG_BUILD_JOBS make_jobs=$SONIC_CONFIG_MAKE_JOBS skip_test=$BUILD_SKIP_TEST"
	echo "docker:   native_dockerd=${SONIC_CONFIG_USE_NATIVE_DOCKERD_FOR_BUILD:-n} slave_driver=${SONIC_SLAVE_DOCKER_DRIVER:-overlay2}"
	echo "disk:     $(df -h --output=avail "$W" | tail -1) free"
	docker version --format 'docker:   {{.Server.Version}}'
	j2 --version | head -1
	if [ $NEED_SUDO = y ]; then
		sudo -n true && echo "sudo:     cached" || { echo "sudo:     NOT cached, run sudo -v first"; exit 1; }
	else
		echo "sudo:     not needed (native build)"
	fi
} 2>&1 | tee "$LOG"

ln -sfn "$(basename "$LOG")" "$W/logs/sonic-build-latest.log"

# Keep a laptop awake for the whole build. Without a login session (e.g. a
# detached run on the board) polkit refuses the inhibitor; run without it.
INHIBIT=""
systemd-inhibit --what=sleep:idle --who=sonic-build true 2>/dev/null &&
	INHIBIT="systemd-inhibit --what=sleep:idle --who=sonic-build --why=SONiC-build"
$INHIBIT bash -c "make $MAKE_EXTRA configure PLATFORM=$PLATFORM PLATFORM_ARCH=$ARCH && make $MAKE_EXTRA $TARGET" \
	>> "$LOG" 2>&1 && rc=0 || rc=$?

{
	echo "end:      $(date -Is)  rc=$rc"
	echo "disk:     $(df -h --output=avail "$W" | tail -1) free"
	ls -l "$TARGET" 2>/dev/null || true
} | tee -a "$LOG"
exit $rc
