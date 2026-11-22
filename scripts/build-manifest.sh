#!/bin/bash
# Write a content manifest of a SONiC build's target/ directory, for comparing
# two builds of the same tree (scripts/compare-builds.sh). Builds embed
# timestamps, so this records content, not checksums:
#   deb  <release>/<name> <version> <arch> <files-digest> <nfiles> <installed-size>
#   docker <image> <packages-digest> <npackages>   (dpkg status inside the image)
#   bin  <file> <packages-digest> <npackages>      (dpkg status in fs.squashfs)
# files-digest: sha256 over "path size" of every file in the .deb (no mtimes).
# Usage: build-manifest.sh <sonic-buildimage dir> > manifest.txt
set -euo pipefail

S=${1:?usage: build-manifest.sh <sonic-buildimage dir>}
T=$S/target
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# "name version arch" per installed package, from a dpkg status file
pkgs() {
	awk '/^Package:/{p=$2} /^Version:/{v=$2} /^Architecture:/{a=$2}
	     /^Status:.*installed/{print p, v, a}' "$1" | sort
}

for d in $(find "$T/debs" -name '*.deb' | sort); do
	f=$(dpkg-deb -f "$d" Package Version Architecture Installed-Size |
		awk -F': ' '{printf "%s ", $2}')
	c=$(dpkg-deb -c "$d" | awk '{print $6, $3}' | sort)
	# key by release dir (debs/bookworm, debs/trixie): names repeat across them
	echo "deb $(basename "$(dirname "$d")")/$f$(echo "$c" | sha256sum | cut -c1-16) $(echo "$c" | wc -l)" |
		awk '{print $1, $2, $3, $4, $6, $7, $5}'
done

# Docker images are "docker save" tarballs: take the last layer that has a
# dpkg status file (layers are listed in order in manifest.json).
for g in $(ls "$T"/docker-*.gz 2>/dev/null | sort); do
	n=$(basename "$g" .gz)
	rm -rf "$TMP/img" && mkdir -p "$TMP/img"
	tar -xzf "$g" -C "$TMP/img" manifest.json 2>/dev/null || { echo "docker $n unreadable 0"; continue; }
	st=""
	for l in $(python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))[0]["Layers"]))' "$TMP/img/manifest.json"); do
		if tar -xzf "$g" -C "$TMP/img" "$l" 2>/dev/null &&
			tar -xf "$TMP/img/$l" -C "$TMP/img" var/lib/dpkg/status 2>/dev/null; then
			st=$(pkgs "$TMP/img/var/lib/dpkg/status")
		fi
		rm -f "$TMP/img/$l"
	done
	echo "docker $n $(echo "$st" | sha256sum | cut -c1-16) $(echo "$st" | grep -c . || true)"
	echo "$st" | sed "s|^|  pkg $n |"
done

# The installer .bin is a shell archive: after the exit_marker line comes a
# tar with installer/fs.zip, which holds fs.squashfs. BINS overrides the list.
for b in ${BINS:-$(ls "$T"/sonic-*.bin 2>/dev/null)}; do
	rm -rf "$TMP/bin" && mkdir -p "$TMP/bin"
	if sed -e '1,/^exit_marker$/d' "$b" | tar -xf - -C "$TMP/bin" 2>/dev/null &&
		z=$(find "$TMP/bin" -name fs.zip | head -1) && [ -n "$z" ] &&
		(cd "$TMP/bin" && unzip -q -o "$z" fs.squashfs 2>/dev/null) &&
		unsquashfs -q -d "$TMP/bin/root" "$TMP/bin/fs.squashfs" var/lib/dpkg/status >/dev/null 2>&1; then
		st=$(pkgs "$TMP/bin/root/var/lib/dpkg/status")
		echo "bin $(basename "$b") $(echo "$st" | sha256sum | cut -c1-16) $(echo "$st" | grep -c .) size=$(stat -c %s "$b")"
		echo "$st" | sed "s|^|  pkg bin |"
	else
		echo "bin $(basename "$b") unreadable 0 size=$(stat -c %s "$b")"
	fi
done
