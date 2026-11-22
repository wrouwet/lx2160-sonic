#!/bin/bash
# Compare two build manifests from build-manifest.sh (e.g. laptop/qemu vs
# board/native build of the same sonic-buildimage commit) and print a
# Markdown report. Exit status 0 if the content matches, 1 if not.
# Usage: compare-builds.sh <manifest-A> <manifest-B> [labelA] [labelB]
set -euo pipefail

A=${1:?usage: compare-builds.sh <manifest-A> <manifest-B> [labelA] [labelB]}
B=${2:?}
LA=${3:-A}
LB=${4:-B}
rc=0

# key -> rest of line, for one record type
rec() { awk -v t="$1" '$1==t {k=$2; $1=""; $2=""; sub(/^  /, ""); print k "\t" $0}' "$2" | sort; }

section() {
	local type=$1 title=$2
	rec "$type" "$A" > /tmp/cmp.a.$$
	rec "$type" "$B" > /tmp/cmp.b.$$
	local na nb same diff
	na=$(wc -l < /tmp/cmp.a.$$)
	nb=$(wc -l < /tmp/cmp.b.$$)
	echo "## $title"
	echo
	echo "- $LA: $na, $LB: $nb"
	only_a=$(join -t $'\t' -v1 /tmp/cmp.a.$$ /tmp/cmp.b.$$ | cut -f1)
	only_b=$(join -t $'\t' -v2 /tmp/cmp.a.$$ /tmp/cmp.b.$$ | cut -f1)
	diff=$(join -t $'\t' /tmp/cmp.a.$$ /tmp/cmp.b.$$ | awk -F'\t' '$2 != $3' | cut -f1)
	same=$(join -t $'\t' /tmp/cmp.a.$$ /tmp/cmp.b.$$ | awk -F'\t' '$2 == $3' | wc -l)
	echo "- identical content: $same"
	if [ -n "$only_a" ]; then echo "- only in $LA: $(echo $only_a)"; rc=1; fi
	if [ -n "$only_b" ]; then echo "- only in $LB: $(echo $only_b)"; rc=1; fi
	if [ -n "$diff" ]; then
		rc=1
		echo "- different content:"
		for k in $diff; do
			echo "  - \`$k\`: $LA \`$(grep -P "^\Q$k\E\t" /tmp/cmp.a.$$ | cut -f2)\` vs $LB \`$(grep -P "^\Q$k\E\t" /tmp/cmp.b.$$ | cut -f2)\`"
			# for images: which installed packages differ
			if [ "$type" != deb ]; then
				diff <(awk -v n="$k" '$1=="pkg" && $2==n {print $3, $4, $5}' "$A") \
					<(awk -v n="$k" '$1=="pkg" && $2==n {print $3, $4, $5}' "$B") |
					grep -E '^[<>]' | sed "s/^</    - $LA:/; s/^>/    - $LB:/" | head -40 || true
			fi
		done
	fi
	echo
	rm -f /tmp/cmp.a.$$ /tmp/cmp.b.$$
}

echo "# Build comparison: $LA vs $LB"
echo
echo "Content comparison (timestamps ignored): .deb file lists and sizes,"
echo "installed packages inside each docker image and in the image's root fs."
echo
section deb "Debian packages"
section docker "Docker images (installed packages)"
section bin "Installer image (root filesystem packages)"
[ $rc = 0 ] && echo "**Result: content identical.**" || echo "**Result: differences found (see above).**"
exit $rc
