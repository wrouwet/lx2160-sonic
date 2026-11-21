#!/bin/sh
# Turn the LX2160ARDB into a native arm64 SONiC build host.
# Run ON THE BOARD as root (sudo). WIPES the SATA SSD given in SSD.
#   - SSD: one ext4 partition mounted at /srv/build (fstab by UUID, nofail)
#   - Docker with its data root on the SSD; $BUILD_USER in the docker group
#   - git, rsync, j2 (jinjanator, in a venv)
set -eu

SSD=${SSD:-/dev/disk/by-id/ata-<model>_<serial>}
MNT=/srv/build
BUILD_USER=${BUILD_USER:-${SUDO_USER:-<user>}}

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -b "$SSD" ] || { echo "no such disk: $SSD" >&2; exit 1; }
if findmnt -rno SOURCE | grep -q "^$(readlink -f "$SSD")"; then
	echo "refusing: a partition of $SSD is mounted" >&2
	exit 1
fi

# Disk: wipe, one GPT partition, ext4
wipefs -a "$SSD"-part* 2>/dev/null || true
wipefs -a "$SSD"
echo 'label: gpt
type=linux, name=sonic-build' | sfdisk -q "$SSD"
udevadm settle
mkfs.ext4 -q -F -L sonic-build "$SSD-part1"
mkdir -p "$MNT"
uuid=$(blkid -s UUID -o value "$SSD-part1")
grep -q "$uuid" /etc/fstab ||
	printf 'UUID=%s\t%s\text4\tdefaults,noatime,nofail\t0 2\n' "$uuid" "$MNT" >> /etc/fstab
systemctl daemon-reload
mount "$MNT"
install -d -o "$BUILD_USER" -g "$BUILD_USER" "$MNT/work"

# Docker, data root on the SSD (written before the package starts dockerd)
mkdir -p /etc/docker
printf '{\n  "data-root": "%s/docker"\n}\n' "$MNT" > /etc/docker/daemon.json
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
	docker.io git rsync make python3-venv iptables >/dev/null
usermod -aG docker "$BUILD_USER"
systemctl restart docker

# j2 for sonic-buildimage, as the build user
su - "$BUILD_USER" -c 'python3 -m venv ~/.local/share/j2-venv &&
	~/.local/share/j2-venv/bin/pip install -q jinjanator &&
	mkdir -p ~/.local/bin && ln -sf ~/.local/share/j2-venv/bin/j2 ~/.local/bin/j2'

df -h "$MNT"
docker info --format 'docker {{.ServerVersion}} root={{.DockerRootDir}} driver={{.Driver}}'
docker run --rm hello-world | grep -m1 Hello
