#!/bin/sh

# Build the deliberately small module-side control-plane sentinel.  A module
# sysroot should be supplied for deployment so the binary links against the
# QDC507's glibc 2.22 rather than the host cross toolchain's newer libc.

set -eu
umask 022

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SOURCE="$PROJECT_DIR/module/djonehubd.c"
OUT_DIR=${OUT_DIR:-"$PROJECT_DIR/outputs/module"}

CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabi-}
CC=${CC:-"${CROSS_COMPILE}gcc"}
READELF=${READELF:-"${CROSS_COMPILE}readelf"}
STRIP=${STRIP:-"${CROSS_COMPILE}strip"}

usage()
{
    printf '%s\n' \
        "Usage: $0 [--local|--module-sysroot]" \
        "  --local           use the installed cross compiler" \
        "  --module-sysroot  link libc and startup files from QDC507 rootfs"
}

require_tool()
{
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'missing required tool: %s\n' "$1" >&2
        exit 1
    fi
}

build()
{
    mode=$1
    require_tool "$CC"
    require_tool "$READELF"
    require_tool "$STRIP"
    mkdir -p "$OUT_DIR"

    temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/djonehubd-build.XXXXXX")
    trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM
    debug_binary="$OUT_DIR/djonehubd.armv7.debug"
    release_binary="$OUT_DIR/djonehubd.armv7"
    audit_report="$OUT_DIR/djonehubd.armv7.audit.txt"

    common_flags="-std=c11 -O2 -g -march=armv7-a -marm -mfloat-abi=softfp -mfpu=neon -fno-pie -fstack-protector-strong -D_FORTIFY_SOURCE=2 -U_TIME_BITS -U_FILE_OFFSET_BITS -ffile-prefix-map=$PROJECT_DIR=/usr/src/djonehub -fdebug-prefix-map=$PROJECT_DIR=/usr/src/djonehub -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Wundef -Werror"

    if [ "$mode" = "module-sysroot" ]; then
        module_rootfs=${MAVO_MODULE_ROOTFS:?set MAVO_MODULE_ROOTFS to the extracted QDC507 rootfs}
        cross_dev_root=${MAVO_CROSS_DEV_ROOT:?set MAVO_CROSS_DEV_ROOT to the extracted usr/arm-linux-gnueabi directory}
        target_triple=$($CC -dumpmachine)
        linux_headers=${MAVO_LINUX_HEADERS:-"/usr/$target_triple/include"}
        gcc_headers=$($CC -print-file-name=include)
        module_lib_dir="$module_rootfs/lib"
        for file in \
            "$module_lib_dir/libc.so.6" "$module_lib_dir/ld-linux.so.3" \
            "$cross_dev_root/include/stdio.h" "$cross_dev_root/lib/crt1.o" \
            "$cross_dev_root/lib/crti.o" "$cross_dev_root/lib/crtn.o" \
            "$cross_dev_root/lib/libc_nonshared.a" "$linux_headers/linux/types.h" \
            "$gcc_headers/stddef.h"; do
            if [ ! -e "$file" ]; then
                printf 'missing module-sysroot input: %s\n' "$file" >&2
                exit 1
            fi
        done
        # shellcheck disable=SC2086
        "$CC" $common_flags -nostdinc -isystem "$cross_dev_root/include" \
            -isystem "$gcc_headers" -isystem "$linux_headers" \
            -fsyntax-only "$SOURCE"
        # shellcheck disable=SC2086
        "$CC" $common_flags -nostdinc -isystem "$cross_dev_root/include" \
            -isystem "$gcc_headers" -isystem "$linux_headers" \
            -c "$SOURCE" -o "$temporary_dir/djonehubd.o"
        crtbegin=$($CC -print-file-name=crtbegin.o)
        crtend=$($CC -print-file-name=crtend.o)
        libgcc=$($CC -print-file-name=libgcc.a)
        "$CC" -nostdlib -no-pie \
            -Wl,-z,relro,-z,now,-z,noexecstack,--as-needed \
            -Wl,--dynamic-linker=/lib/ld-linux.so.3 -o "$debug_binary" \
            "$cross_dev_root/lib/crt1.o" "$cross_dev_root/lib/crti.o" \
            "$crtbegin" "$temporary_dir/djonehubd.o" -L"$module_lib_dir" \
            -Wl,-rpath-link,"$module_lib_dir" -Wl,--no-as-needed \
            -Wl,-l:libc.so.6 "$cross_dev_root/lib/libc_nonshared.a" \
            "$libgcc" -Wl,-l:ld-linux.so.3 "$crtend" "$cross_dev_root/lib/crtn.o"
    else
        # This path is useful for syntax and ABI checks.  Do not deploy its
        # output unless the compiler's libc is known to match the module.
        # shellcheck disable=SC2086
        "$CC" $common_flags -pthread "$SOURCE" -o "$debug_binary"
    fi

    "$STRIP" --strip-unneeded -o "$release_binary" "$debug_binary"
    "$READELF" --file-header "$release_binary" >"$audit_report"
    "$READELF" --program-headers --wide "$release_binary" >>"$audit_report"
    "$READELF" --dynamic "$release_binary" >>"$audit_report"
    printf 'source=%s\n' "$SOURCE" >>"$audit_report"
    printf 'source_sha256=' >>"$audit_report"
    require_tool sha256sum
    sha256sum "$SOURCE" | awk '{print $1}' >>"$audit_report"
    printf 'built: %s\n' "$release_binary"
    printf 'audit: %s\n' "$audit_report"
}

case ${1:-"--local"} in
    --local) build local ;;
    --module-sysroot) build module-sysroot ;;
    --help|-h) usage ;;
    *) usage >&2; exit 2 ;;
esac
