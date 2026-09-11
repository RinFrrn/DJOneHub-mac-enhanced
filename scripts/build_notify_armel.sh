#!/bin/sh
# Static Go TLS/Web Push sender + the existing, ABI-audited QMI C runtime.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
OUT_DIR=${OUT_DIR:-"$PROJECT_DIR/outputs/module"}
export OUT_DIR
mkdir -p "$OUT_DIR"
cd "$PROJECT_DIR"
NOTIFY_OVERLAY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/djonehub-notify-overlay.XXXXXX")
trap 'rm -rf "$NOTIFY_OVERLAY_DIR"' EXIT HUP INT TERM
python3 "$SCRIPT_DIR/prepare_notify_go_overlay.py" "$NOTIFY_OVERLAY_DIR"
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7,softfloat \
    go build -overlay="$NOTIFY_OVERLAY_DIR/overlay.json" -trimpath -ldflags='-s -w -buildid=' \
    -o "$OUT_DIR/djonehub-notify.armv7" ./cmd/djonehub-notify
{
    go version
    printf 'go_entropy_source_sha256='
    cat "$NOTIFY_OVERLAY_DIR/source.sha256"
    printf 'go_entropy_overlay=lazy-scratch-allocation\n'
    python3 "$SCRIPT_DIR/audit_notify_elf.py" "$OUT_DIR/djonehub-notify.armv7"
} > "$OUT_DIR/djonehub-notify.armv7.audit.txt"
DJONEHUB_QMI_BUILD_TARGET=notify-monitor \
    "$SCRIPT_DIR/build_sms_daemon_armel.sh" "${1:---container}"
LICENSE_DIR="$OUT_DIR/djonehub-notify-licenses"
mkdir -p "$LICENSE_DIR"
# Module-cache license files are commonly read-only. Generated copies from a
# previous build must be writable before they can be refreshed.
for old_license in "$LICENSE_DIR"/*; do
    [ -e "$old_license" ] || break
    chmod u+w "$old_license"
done
GO_LICENSE="$(go env GOROOT)/LICENSE"
# Homebrew installs the toolchain license beside libexec rather than inside it.
if [ ! -f "$GO_LICENSE" ]; then
    GO_LICENSE="$(go env GOROOT)/../LICENSE"
fi
cp "$GO_LICENSE" "$LICENSE_DIR/Go-LICENSE"
for dependency in github.com/SherClockHolmes/webpush-go github.com/golang-jwt/jwt/v5 golang.org/x/crypto; do
    dependency_dir=$(go list -m -f '{{.Dir}}' "$dependency")
    license_name=$(printf '%s' "$dependency" | tr '/' '_')
    cp "$dependency_dir/LICENSE" "$LICENSE_DIR/$license_name-LICENSE"
done
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUT_DIR" && sha256sum djonehub-notify.armv7 > djonehub-notify.armv7.sha256)
else
    (cd "$OUT_DIR" && shasum -a 256 djonehub-notify.armv7 > djonehub-notify.armv7.sha256)
fi
printf 'Built sender and monitor in %s\n' "$OUT_DIR"
