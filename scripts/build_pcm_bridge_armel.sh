#!/bin/sh

# Reproducible ARMv7 soft-float build and offline ELF audit for the module-side
# PCM bridge.  The default path uses a pinned Debian 11 amd64 container and
# exact cross-toolchain package versions.  --local skips Docker when those
# tools are already installed.

set -eu
umask 022

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SOURCE="$PROJECT_DIR/module/mavo_pcm_bridge.c"
OUT_DIR=${OUT_DIR:-"$PROJECT_DIR/outputs/module"}

BUILDER_IMAGE=${MAVO_PCM_BUILDER_IMAGE:-"debian@sha256:19d6c1c4e66453a5d729cf13c3dcdb4708aeff1b2ed9886805afcda191f064b7"}

CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabi-}
CC=${CC:-"${CROSS_COMPILE}gcc"}
READELF=${READELF:-"${CROSS_COMPILE}readelf"}
STRINGS=${STRINGS:-"${CROSS_COMPILE}strings"}
STRIP=${STRIP:-"${CROSS_COMPILE}strip"}

usage()
{
    printf '%s\n' \
        "Usage: $0 [--container|--local|--module-sysroot]" \
        "  --container  use the pinned Debian builder (default)" \
        "  --local      use an installed arm-linux-gnueabi toolchain" \
        "  --module-sysroot  link against an extracted QDC507 rootfs"
}

require_tool()
{
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'missing required tool: %s\n' "$1" >&2
        exit 1
    fi
}

audit_glibc_versions()
{
    binary=$1

    "$READELF" --version-info "$binary" |
        grep -o 'GLIBC_[0-9][0-9.]*' |
        sort -u |
        while IFS= read -r version; do
            number=${version#GLIBC_}
            major=${number%%.*}
            remainder=${number#*.}
            minor=${remainder%%.*}
            if [ "$major" -gt 2 ] ||
               { [ "$major" -eq 2 ] && [ "$minor" -gt 22 ]; }; then
                printf 'unsupported runtime symbol version: %s\n' \
                    "$version" >&2
                exit 1
            fi
        done
}

audit_binary()
{
    binary=$1
    header=$("$READELF" --file-header "$binary")
    attributes=$("$READELF" --arch-specific "$binary")
    programs=$("$READELF" --program-headers --wide "$binary")
    dynamic=$("$READELF" --dynamic "$binary")

    printf '%s\n' "$header" | grep -q 'Class:.*ELF32'
    printf '%s\n' "$header" | grep -q 'Type:.*EXEC'
    printf '%s\n' "$header" | grep -q 'Machine:.*ARM'
    printf '%s\n' "$header" | grep -q 'Version5 EABI, soft-float ABI'
    printf '%s\n' "$attributes" | grep -q 'Tag_CPU_arch: v7'
    if printf '%s\n' "$attributes" | grep -q 'Tag_ABI_VFP_args:.*VFP registers'; then
        printf '%s\n' 'hard-float ABI is incompatible with the vendor library' >&2
        return 1
    fi
    printf '%s\n' "$programs" | grep -q '/lib/ld-linux.so.3'
    printf '%s\n' "$programs" | grep -q 'GNU_RELRO'
    if printf '%s\n' "$programs" | grep 'GNU_STACK' | grep -q 'RWE'; then
        printf '%s\n' 'executable stack detected' >&2
        return 1
    fi
    printf '%s\n' "$dynamic" | grep -q 'BIND_NOW'

    needed=$(printf '%s\n' "$dynamic" |
        sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
    for library in $needed; do
        case "$library" in
            libc.so.6|libdl.so.2|libpthread.so.0|ld-linux.so.3) ;;
            *)
                printf 'unexpected direct dependency: %s\n' "$library" >&2
                return 1
                ;;
        esac
    done
    for library in libc.so.6 libdl.so.2 libpthread.so.0 ld-linux.so.3; do
        printf '%s\n' "$needed" | grep -qx "$library"
    done

    audit_glibc_versions "$binary"

    exported_functions=$("$READELF" --dyn-syms --wide "$binary" |
        awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" { print $8 }')
    if [ "$exported_functions" != "main" ]; then
        printf 'unexpected bridge function exports: %s\n' \
            "$exported_functions" >&2
        return 1
    fi

    for symbol in \
        quec_pcm_open \
        quec_pcm_close \
        quec_read_pcm \
        quec_write_pcm \
        quec_get_pem_buffer_len \
        quectel_clt_set_mixer_value; do
        "$STRINGS" "$binary" | grep -qx "$symbol"
    done
}

build_local()
{
    require_tool "$CC"
    require_tool "$READELF"
    require_tool "$STRINGS"
    require_tool "$STRIP"
    require_tool sha256sum

    mkdir -p "$OUT_DIR"
    temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/mavo-pcm-build.XXXXXX")
    trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

    debug_binary="$OUT_DIR/mavo-pcm-bridge.armv7.debug"
    release_binary="$OUT_DIR/mavo-pcm-bridge.armv7"
    audit_report="$OUT_DIR/mavo-pcm-bridge.armv7.audit.txt"
    checksum_file="$OUT_DIR/mavo-pcm-bridge.armv7.sha256"

    # Keep the original 32-bit off_t/time ABI. Newer cross-libc headers can
    # otherwise redirect fcntl to the GLIBC_2.28 symbol, which is unavailable
    # on the QDC507 module's glibc 2.22 runtime.
    common_flags="-std=c11 -O2 -g -march=armv7-a -marm -mfloat-abi=softfp -mfpu=neon -fno-pie -fstack-protector-strong -D_FORTIFY_SOURCE=2 -U_TIME_BITS -U_FILE_OFFSET_BITS -ffile-prefix-map=$PROJECT_DIR=/usr/src/mavo -fdebug-prefix-map=$PROJECT_DIR=/usr/src/mavo -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Wundef -Werror"
    # liblog.so.0 in the target rootfs has an intentional reverse reference to
    # main.  Export that one symbol, but keep every bridge helper static.
    linker_flags="-no-pie -Wl,-z,relro,-z,now,-z,noexecstack,--as-needed,--build-id=sha1,--export-dynamic-symbol=main"

    # Strict compilation plus GCC's interprocedural static analyzer.  Neither
    # command executes target code or accesses any device.
    # shellcheck disable=SC2086
    "$CC" $common_flags -pthread -fsyntax-only "$SOURCE"
    # shellcheck disable=SC2086
    "$CC" $common_flags -fanalyzer -pthread -c "$SOURCE" \
        -o "$temporary_dir/mavo_pcm_bridge.analyzer.o"
    # shellcheck disable=SC2086
    "$CC" $common_flags -pthread "$SOURCE" $linker_flags -ldl \
        -o "$debug_binary"
    "$STRIP" --strip-unneeded -o "$release_binary" "$debug_binary"

    audit_binary "$debug_binary"
    audit_binary "$release_binary"

    {
        printf 'source=%s\n' "$SOURCE"
        printf 'source_sha256='
        sha256sum "$SOURCE" | awk '{print $1}'
        printf 'compiler=%s\n' "$("$CC" -dumpfullversion -dumpversion)"
        printf 'binutils=%s\n' \
            "$("$READELF" --version | sed -n '1s/.* //p')"
        printf 'target=ARMv7 EABI5 soft-float (arm-linux-gnueabi)\n'
        printf 'maximum_glibc=2.22\n'
        printf 'runtime_needed=%s\n' \
            "$("$READELF" -d "$release_binary" |
               sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' |
               tr '\n' ' ')"
        "$READELF" --file-header "$release_binary"
        "$READELF" --arch-specific "$release_binary"
        "$READELF" --version-info "$release_binary"
    } >"$audit_report"

    (
        cd "$OUT_DIR"
        sha256sum \
            "$(basename "$debug_binary")" \
            "$(basename "$release_binary")" \
            "$(basename "$audit_report")" >"$(basename "$checksum_file")"
    )

    printf 'built: %s\n' "$release_binary"
    printf 'audit: %s\n' "$audit_report"
}

build_module_sysroot()
{
    require_tool "$CC"
    require_tool "$READELF"
    require_tool "$STRINGS"
    require_tool "$STRIP"
    require_tool sha256sum

    module_rootfs=${MAVO_MODULE_ROOTFS:?set MAVO_MODULE_ROOTFS to the extracted QDC507 rootfs}
    cross_dev_root=${MAVO_CROSS_DEV_ROOT:?set MAVO_CROSS_DEV_ROOT to the extracted usr/arm-linux-gnueabi directory}
    target_triple=$($CC -dumpmachine)
    linux_headers=${MAVO_LINUX_HEADERS:-"/usr/$target_triple/include"}
    gcc_headers=$($CC -print-file-name=include)
    module_lib_dir="$module_rootfs/lib"

    for file in \
        "$module_lib_dir/libc.so.6" \
        "$module_lib_dir/libdl.so.2" \
        "$module_lib_dir/libpthread.so.0" \
        "$module_lib_dir/ld-linux.so.3" \
        "$cross_dev_root/include/stdio.h" \
        "$cross_dev_root/lib/crt1.o" \
        "$cross_dev_root/lib/crti.o" \
        "$cross_dev_root/lib/crtn.o" \
        "$cross_dev_root/lib/libc_nonshared.a" \
        "$linux_headers/linux/types.h" \
        "$gcc_headers/stddef.h"; do
        if [ ! -e "$file" ]; then
            printf 'missing module-sysroot input: %s\n' "$file" >&2
            exit 1
        fi
    done

    mkdir -p "$OUT_DIR"
    temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/mavo-pcm-module-build.XXXXXX")
    trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

    object="$temporary_dir/mavo_pcm_bridge.o"
    debug_binary="$OUT_DIR/mavo-pcm-bridge.armv7.debug"
    release_binary="$OUT_DIR/mavo-pcm-bridge.armv7"
    audit_report="$OUT_DIR/mavo-pcm-bridge.armv7.audit.txt"
    checksum_file="$OUT_DIR/mavo-pcm-bridge.armv7.sha256"

    # Ubuntu 26 arm-linux-gnueabi defaults to the 64-bit time/off_t ABI.  The
    # QDC507 ships glibc 2.22 and has neither fcntl64 nor the time64 entry
    # points, so explicitly retain its original 32-bit ABI.  The libc headers
    # and startup objects come from the pinned Bullseye cross-dev package;
    # shared objects come from the same module image used for deployment.
    common_flags="-std=c11 -O2 -g -march=armv7-a -marm -mfloat-abi=softfp -mfpu=neon -fno-pie -fstack-protector-strong -D_FORTIFY_SOURCE=2 -U_TIME_BITS -U_FILE_OFFSET_BITS -ffile-prefix-map=$PROJECT_DIR=/usr/src/mavo -fdebug-prefix-map=$PROJECT_DIR=/usr/src/mavo -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Wundef -Werror"
    # shellcheck disable=SC2086
    "$CC" $common_flags -nostdinc \
        -isystem "$cross_dev_root/include" \
        -isystem "$gcc_headers" \
        -isystem "$linux_headers" \
        -pthread -fsyntax-only "$SOURCE"
    # shellcheck disable=SC2086
    "$CC" $common_flags -nostdinc \
        -isystem "$cross_dev_root/include" \
        -isystem "$gcc_headers" \
        -isystem "$linux_headers" \
        -fanalyzer -pthread -c "$SOURCE" \
        -o "$temporary_dir/mavo_pcm_bridge.analyzer.o"
    # shellcheck disable=SC2086
    "$CC" $common_flags -nostdinc \
        -isystem "$cross_dev_root/include" \
        -isystem "$gcc_headers" \
        -isystem "$linux_headers" \
        -pthread -c "$SOURCE" -o "$object"

    crtbegin=$($CC -print-file-name=crtbegin.o)
    crtend=$($CC -print-file-name=crtend.o)
    libgcc=$($CC -print-file-name=libgcc.a)
    for file in "$crtbegin" "$crtend" "$libgcc"; do
        if [ ! -e "$file" ]; then
            printf 'missing compiler runtime input: %s\n' "$file" >&2
            exit 1
        fi
    done

    "$CC" -nostdlib -no-pie \
        -Wl,-z,relro,-z,now,-z,noexecstack,--as-needed,--build-id=sha1,--export-dynamic-symbol=main \
        -Wl,--dynamic-linker=/lib/ld-linux.so.3 \
        -o "$debug_binary" \
        "$cross_dev_root/lib/crt1.o" \
        "$cross_dev_root/lib/crti.o" \
        "$crtbegin" \
        "$object" \
        -L"$module_lib_dir" \
        -Wl,-rpath-link,"$module_lib_dir" \
        -Wl,--no-as-needed \
        -Wl,-l:libpthread.so.0 \
        -Wl,-l:libdl.so.2 \
        -Wl,--as-needed \
        -Wl,-l:libc.so.6 \
        "$cross_dev_root/lib/libc_nonshared.a" \
        "$libgcc" \
        -Wl,--no-as-needed \
        -Wl,-l:ld-linux.so.3 \
        "$crtend" \
        "$cross_dev_root/lib/crtn.o"
    "$STRIP" --strip-unneeded -o "$release_binary" "$debug_binary"

    audit_binary "$debug_binary"
    audit_binary "$release_binary"

    {
        printf 'source=%s\n' "$SOURCE"
        printf 'source_sha256='
        sha256sum "$SOURCE" | awk '{print $1}'
        printf 'compiler=%s\n' "$($CC -dumpfullversion -dumpversion)"
        printf 'binutils=%s\n' \
            "$($READELF --version | sed -n '1s/.* //p')"
        printf 'target=ARMv7 EABI5 soft-float (arm-linux-gnueabi)\n'
        printf 'module_rootfs=%s\n' "$module_rootfs"
        printf 'module_libc_sha256='
        sha256sum "$module_lib_dir/libc.so.6" | awk '{print $1}'
        printf 'cross_libc_nonshared_sha256='
        sha256sum "$cross_dev_root/lib/libc_nonshared.a" | awk '{print $1}'
        printf 'maximum_glibc=2.22\n'
        printf 'runtime_needed=%s\n' \
            "$($READELF -d "$release_binary" |
               sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' |
               tr '\n' ' ')"
        "$READELF" --file-header "$release_binary"
        "$READELF" --arch-specific "$release_binary"
        "$READELF" --version-info "$release_binary"
    } >"$audit_report"

    (
        cd "$OUT_DIR"
        sha256sum \
            "$(basename "$debug_binary")" \
            "$(basename "$release_binary")" \
            "$(basename "$audit_report")" >"$(basename "$checksum_file")"
    )

    printf 'built against module sysroot: %s\n' "$release_binary"
    printf 'audit: %s\n' "$audit_report"
}

build_container()
{
    require_tool docker
    mkdir -p "$OUT_DIR"

    host_uid=$(id -u)
    host_gid=$(id -g)
    docker run --rm --platform linux/amd64 \
        -e OUT_DIR=/out \
        -e SOURCE_DATE_EPOCH=1783785600 \
        -e HOST_UID="$host_uid" \
        -e HOST_GID="$host_gid" \
        -v "$PROJECT_DIR:/src:ro" \
        -v "$OUT_DIR:/out" \
        "$BUILDER_IMAGE" sh -ec '
            printf "%s\n" \
                "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260421T000000Z bullseye main" \
                >/etc/apt/sources.list
            apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Retries=3 update
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                binutils-arm-linux-gnueabi=2.35.2-2 \
                gcc-arm-linux-gnueabi=4:10.2.1-1 \
                gcc-10-arm-linux-gnueabi=10.2.1-6cross1 \
                libc6-dev-armel-cross=2.31-9cross4
            /src/scripts/build_pcm_bridge_armel.sh --local
            chown -R "$HOST_UID:$HOST_GID" /out 2>/dev/null || true
        '
}

case ${1:-"--container"} in
    --container) build_container ;;
    --local) build_local ;;
    --module-sysroot) build_module_sysroot ;;
    --help|-h) usage ;;
    *) usage >&2; exit 2 ;;
esac
