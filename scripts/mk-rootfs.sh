#!/bin/sh
# Build a Debian 13 (trixie) arm64 rootfs tarball for the LX2160ARDB.
# Needs root (mmdebstrap root mode) and qemu-user-binfmt for arm64.
# Kernel, modules and extlinux.conf are added afterwards by mk-sdcard.sh,
# which runs unprivileged.
set -eu

W=${W:-/home/${SUDO_USER:-$USER}/lx2160-workspace}
OUT=${1:-$W/out/rootfs-trixie-arm64.tar}
HOSTNAME=${HOSTNAME_BOARD:-lx2160ardb}
USERNAME=${USERNAME_BOARD:-${SUDO_USER:-debian}}
SSHKEY=${SSHKEY:-/home/$USERNAME/.ssh/id_ed25519.pub}

PKGS="systemd-sysv,systemd-resolved,systemd-timesyncd,udev,dbus,openssh-server,\
sudo,locales,ca-certificates,iproute2,iputils-ping,ethtool,tcpdump,curl,wget,\
less,vim-tiny,bash-completion,pciutils,usbutils,i2c-tools,mmc-utils,mtd-utils,\
lm-sensors,e2fsprogs,fdisk,cloud-guest-utils,kmod,linux-sysctl-defaults,iperf3"

mkdir -p "$(dirname "$OUT")"

# Never prompt, and keep mmdebstrap off the terminal entirely: under sudo's
# pty, the whole process group got stopped (state T) as soon as apt started
# dpkg. setsid + stdin from /dev/null leaves no controlling tty to stop it.
export DEBIAN_FRONTEND=noninteractive

setsid -w mmdebstrap --arch=arm64 --variant=minbase \
	--include="$PKGS" \
	--components=main,non-free-firmware \
	--customize-hook="echo $HOSTNAME > \$1/etc/hostname" \
	--customize-hook="printf '127.0.0.1\tlocalhost\n127.0.1.1\t$HOSTNAME\n' > \$1/etc/hosts" \
	--customize-hook="printf '/dev/root\t/\text4\tdefaults,noatime\t0 1\n' > \$1/etc/fstab" \
	--customize-hook='mkdir -p $1/etc/systemd/network && printf "[Match]\nName=e*\n\n[Network]\nDHCP=yes\n" > $1/etc/systemd/network/50-dhcp.network' \
	--customize-hook='chroot $1 systemctl enable systemd-networkd systemd-resolved ssh' \
	--customize-hook="chroot \$1 useradd -m -s /bin/bash -G sudo $USERNAME" \
	--customize-hook="echo '$USERNAME:lx2160' | chroot \$1 chpasswd" \
	--customize-hook="echo 'root:root' | chroot \$1 chpasswd" \
	--customize-hook="mkdir -p \$1/home/$USERNAME/.ssh && cp $SSHKEY \$1/home/$USERNAME/.ssh/authorized_keys && chroot \$1 chown -R $USERNAME: /home/$USERNAME/.ssh && chmod 700 \$1/home/$USERNAME/.ssh" \
	trixie "$OUT" http://deb.debian.org/debian </dev/null

chown "${SUDO_USER:-root}:" "$OUT"
ls -l "$OUT"
