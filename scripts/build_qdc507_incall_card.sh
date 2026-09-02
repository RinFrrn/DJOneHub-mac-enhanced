#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KERNEL_TREE=${QDC507_KERNEL_TREE:?set QDC507_KERNEL_TREE to the prepared QDC507 3.18.44 kernel tree}
KERNEL_CC=${QDC507_KERNEL_CC:-"$KERNEL_TREE/tools/clang-armv7-kernel"}
CROSS_COMPILE=${QDC507_CROSS_COMPILE:-arm-linux-gnueabihf-}
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/outputs/module"}
EXPECTED_SHA256=dfabcecff905b97ed46f755f4667e7c2635799e00524a10a8ed9d546bd1feea7
PINNED_BINUTILS_VERSION=2.35.2
LINK_CONTAINER=${QDC507_LINK_CONTAINER:-qdc-arm-toolchain}

test -f "$KERNEL_TREE/.config"
test -x "$KERNEL_CC"
command -v "${CROSS_COMPILE}ld" >/dev/null

build_dir=$(mktemp -d "${TMPDIR:-/tmp}/qdc507-incall-card.XXXXXX")
remote_link_dir=
cleanup() {
	if test -n "$remote_link_dir"; then
		docker exec "$LINK_CONTAINER" sh -c 'rm -rf "$1"' sh "$remote_link_dir" >/dev/null 2>&1 || true
	fi
	rm -rf "$build_dir"
}
trap cleanup EXIT HUP INT TERM

install -m 644 "$ROOT_DIR/module/qdc507_incall_card.c" "$build_dir/qdc507_incall_card.c"
cat >"$build_dir/Makefile" <<'EOF'
obj-m += qdc507_incall_card.o
ccflags-y += -fno-pic -fno-pie -fno-addrsig -g0
ccflags-y += -I$(srctree)/sound/soc/msm/qdsp6v2
EOF

make -C "$KERNEL_TREE" \
	ARCH=arm \
	CROSS_COMPILE="$CROSS_COMPILE" \
	CC="$KERNEL_CC" \
	M="$build_dir" \
	modules

mkdir -p "$OUT_DIR"
output="$OUT_DIR/qdc507_incall_card.new.ko"
candidate="$build_dir/qdc507_incall_card.pinned.ko"

# GNU ld 2.47 orders otherwise equivalent ELF sections differently from the
# module that passed hardware validation. Link with the pinned Bullseye 2.35.2
# binutils used by the ARM helper container so the deployed SHA-256 remains
# byte-for-byte reproducible.
if command -v arm-linux-gnueabi-ld >/dev/null 2>&1 &&
   arm-linux-gnueabi-ld --version | grep -Fq "$PINNED_BINUTILS_VERSION"; then
	arm-linux-gnueabi-ld -r \
		-T "$KERNEL_TREE/scripts/module-common.lds" \
		-o "$candidate" \
		"$build_dir/qdc507_incall_card.o" \
		"$build_dir/qdc507_incall_card.mod.o"
else
	command -v docker >/dev/null
	docker exec "$LINK_CONTAINER" arm-linux-gnueabi-ld --version |
		grep -Fq "$PINNED_BINUTILS_VERSION"
	remote_link_dir="/tmp/qdc507-incall-card-link-$$"
	docker exec "$LINK_CONTAINER" mkdir -p "$remote_link_dir"
	docker cp "$build_dir/qdc507_incall_card.o" "$LINK_CONTAINER:$remote_link_dir/qdc507_incall_card.o" >/dev/null
	docker cp "$build_dir/qdc507_incall_card.mod.o" "$LINK_CONTAINER:$remote_link_dir/qdc507_incall_card.mod.o" >/dev/null
	docker cp "$KERNEL_TREE/scripts/module-common.lds" "$LINK_CONTAINER:$remote_link_dir/module-common.lds" >/dev/null
	docker exec "$LINK_CONTAINER" arm-linux-gnueabi-ld -r \
		-T "$remote_link_dir/module-common.lds" \
		-o "$remote_link_dir/qdc507_incall_card.ko" \
		"$remote_link_dir/qdc507_incall_card.o" \
		"$remote_link_dir/qdc507_incall_card.mod.o"
	docker cp "$LINK_CONTAINER:$remote_link_dir/qdc507_incall_card.ko" "$candidate" >/dev/null
fi

actual=$(shasum -a 256 "$candidate" | awk '{print $1}')
if test "$actual" != "$EXPECTED_SHA256"; then
	printf '%s\n' "qdc507 in-call card hash mismatch: expected $EXPECTED_SHA256, got $actual" >&2
	exit 1
fi
install -m 644 "$candidate" "$output"
printf '%s  %s\n' "$actual" "$(basename -- "$output")" >"$output.sha256"
file "$output"
printf '%s\n' "verified qdc507 in-call card: $actual"
