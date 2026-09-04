#!/bin/sh

# Reproducible ARMv7 soft-float build for the authenticated QDC507 SMS/WMS
# gateway.  It links only libc, libpthread and libdl; QMI libraries are loaded
# at runtime from the module so the binary never vendors modem ABI material.

set -eu
umask 022

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
OUT_DIR=${OUT_DIR:-"$PROJECT_DIR/outputs/module"}
BUILDER_IMAGE=${DJONEHUB_SMS_BUILDER_IMAGE:-"debian@sha256:19d6c1c4e66453a5d729cf13c3dcdb4708aeff1b2ed9886805afcda191f064b7"}

CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabi-}
CC=${CC:-"${CROSS_COMPILE}gcc"}
READELF=${READELF:-"${CROSS_COMPILE}readelf"}
STRIP=${STRIP:-"${CROSS_COMPILE}strip"}

SOURCES="
$PROJECT_DIR/module/djonehub_sms_daemon.c
$PROJECT_DIR/module/djonehub_qmi_wms_engine.c
$PROJECT_DIR/module/djonehub_wms_codec.c
$PROJECT_DIR/module/djonehub_sms_protocol.c
$PROJECT_DIR/module/djonehub_crypto.c
"

require_tool()
{
    command -v "$1" >/dev/null 2>&1 || {
        printf 'missing required tool: %s\n' "$1" >&2
        exit 1
    }
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
    printf '%s\n' "$attributes" | grep -q 'Tag_CPU_arch: v7'
    if printf '%s\n' "$attributes" | grep -q 'Tag_ABI_VFP_args:.*VFP registers'; then
        printf '%s\n' 'hard-float ABI is incompatible with QDC507' >&2
        return 1
    fi
    printf '%s\n' "$programs" | grep -q '/lib/ld-linux.so.3'
    if printf '%s\n' "$programs" | grep 'GNU_STACK' | grep -q 'RWE'; then
        printf '%s\n' 'executable stack detected' >&2
        return 1
    fi
    printf '%s\n' "$dynamic" | grep -q 'BIND_NOW'
    if printf '%s\n' "$dynamic" | grep -q GNU_HASH; then
        printf '%s\n' 'QDC507 loader requires a SysV hash table' >&2
        return 1
    fi
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
                printf 'unsupported runtime symbol version: %s\n' "$version" >&2
                exit 1
            fi
        done
}

build_local()
{
    require_tool "$CC"
    require_tool "$READELF"
    require_tool "$STRIP"
    require_tool sha256sum
    mkdir -p "$OUT_DIR"

    debug_binary="$OUT_DIR/djonehub-sms-daemon.armv7.debug"
    release_binary="$OUT_DIR/djonehub-sms-daemon.armv7"
    audit_report="$OUT_DIR/djonehub-sms-daemon.armv7.audit.txt"
    checksum_file="$OUT_DIR/djonehub-sms-daemon.armv7.sha256"
    common_flags="-std=c11 -O2 -g -march=armv7-a -marm -mfloat-abi=softfp -mfpu=neon -fno-pie -fstack-protector-strong -D_FORTIFY_SOURCE=2 -U_TIME_BITS -U_FILE_OFFSET_BITS -ffile-prefix-map=$PROJECT_DIR=/usr/src/djonehub -fdebug-prefix-map=$PROJECT_DIR=/usr/src/djonehub -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Wundef -Werror"

    # shellcheck disable=SC2086
    "$CC" $common_flags -pthread -fsyntax-only $SOURCES
    # shellcheck disable=SC2086
    "$CC" $common_flags -pthread $SOURCES \
        -no-pie -Wl,--hash-style=sysv,-z,relro,-z,now,-z,noexecstack,--as-needed \
        -ldl -o "$debug_binary"
    "$STRIP" --strip-unneeded -o "$release_binary" "$debug_binary"
    audit_binary "$debug_binary"
    audit_binary "$release_binary"

    {
        printf 'target=ARMv7 EABI5 soft-float\n'
        printf 'listen=192.168.225.1:45752\n'
        printf 'scope=status/list/read/send-raw/delete\n'
        printf 'arbitrary_at_or_qmi=false\n'
        printf 'maximum_glibc=2.22\n'
        for source in $SOURCES; do
            printf 'source_sha256 %s ' "${source#$PROJECT_DIR/}"
            sha256sum "$source" | awk '{print $1}'
        done
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
}

build_container()
{
    require_tool docker
    mkdir -p "$OUT_DIR"
    host_uid=$(id -u)
    host_gid=$(id -g)
    docker run --rm --platform linux/amd64 \
        -e OUT_DIR=/out \
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
            /src/scripts/build_sms_daemon_armel.sh --local
            chown -R "$HOST_UID:$HOST_GID" /out 2>/dev/null || true
        '
}

case ${1:-"--container"} in
    --container) build_container ;;
    --local) build_local ;;
    --help|-h) printf '%s\n' "Usage: $0 [--container|--local]" ;;
    *) printf '%s\n' "Usage: $0 [--container|--local]" >&2; exit 2 ;;
esac
