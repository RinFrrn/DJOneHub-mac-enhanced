package main

import (
	"errors"
	"fmt"
	"strings"
)

type moduleNotifyOptions struct {
	Action, ArtifactDir, ConfigPath, CAPath, PairingRegistryPath string
}

const moduleNotifyDir = "/usrdata/djonehub/notify"
const moduleNotifyInitLink = "/etc/rc5.d/S97djonehub-notify"

const moduleNotifyStartScript = `#!/bin/sh
directory=/usrdata/djonehub/notify
binary=$directory/djonehub-notify.armv7
pidfile=$directory/notify.pid
registry=/usrdata/djonehub/pairing/registry.json
owned() {
    test -s "$pidfile" || return 1
    read pid < "$pidfile"
    case "$pid" in ''|*[!0-9]*) return 1;; esac
    test "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$binary"
}
case "${1:-start}" in
start)
    if owned; then exit 0; fi
    rm -f "$pidfile"
    ulimit -c 0
    registry_arg=
    if test -f "$registry"; then registry_arg="-experimental-pairing-registry $registry"; fi
    env GOMEMLIMIT=6MiB GOGC=25 GOMAXPROCS=1 \
        SSL_CERT_FILE="$directory/ca.pem" LD_LIBRARY_PATH=/usr/lib \
        "$binary" -config "$directory/config.json" \
        -monitor "$directory/djonehub-notify-monitor.armv7" \
        -log-file "$directory/notify.log" $registry_arg </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$pidfile"
    ;;
stop)
    if owned; then kill -TERM "$pid"; fi
    rm -f "$pidfile"
    ;;
esac
`

// There is no arbitrary shell input. Local paths are used only by os.ReadFile
// and ADB sync; these remote commands contain fixed allowlisted paths/actions.
func moduleNotifyCommand(action string) (string, error) {
	base := "GOMEMLIMIT=6MiB GOGC=25 GOMAXPROCS=1 SSL_CERT_FILE=" + moduleNotifyDir + "/ca.pem LD_LIBRARY_PATH=/usr/lib "
	binary := moduleNotifyDir + "/djonehub-notify.armv7"
	config := " -config " + moduleNotifyDir + "/config.json"
	owned := `owned() { test -s '` + moduleNotifyDir + `/notify.pid' || return 1; read pid < '` + moduleNotifyDir + `/notify.pid'; case "$pid" in ''|*[!0-9]*) return 1;; esac; test "$(readlink "/proc/$pid/exe" 2>/dev/null)" = '` + binary + `'; }; `
	switch action {
	case "storage":
		return "df -k /usrdata; du -k /usrdata/djonehub/* 2>/dev/null; ls -la /usrdata/djonehub/notify /usrdata/djonehub/voice-test", nil
	case "status":
		return owned + `if owned; then echo 'running'; else echo 'stopped'; fi`, nil
	case "stop":
		return owned + `if owned; then kill -TERM "$pid"; attempt=0; while owned && test "$attempt" -lt 100; do sleep 0.1; attempt=$((attempt+1)); done; owned && exit 1; fi; rm -f '` + moduleNotifyDir + `/notify.pid'; echo 'stopped'`, nil
	case "start":
		registry := `registry_arg=''; test ! -f '/usrdata/djonehub/pairing/registry.json' || registry_arg='-experimental-pairing-registry /usrdata/djonehub/pairing/registry.json'; `
		return owned + `if owned; then echo 'already running'; else ` +
			base + binary + config + ` -check && { ` +
			registry + `(trap '' HUP; exec ` + "env " + base + binary + config + " -monitor " + moduleNotifyDir + `/djonehub-notify-monitor.armv7 -log-file ` + moduleNotifyDir + `/notify.log $registry_arg) </dev/null >/dev/null 2>&1 & pid=$!; ` +
			`printf '%s\n' "$pid" > '` + moduleNotifyDir + `/notify.pid'; sleep 1; owned; }; fi`, nil
	case "test-bark", "test-webpush":
		return base + binary + config + " -test " + strings.TrimPrefix(action, "test-"), nil
	case "probe-network":
		return base + binary + " -probe-network", nil
	case "probe-runtime":
		return base + binary + config + " -monitor " + moduleNotifyDir + "/djonehub-notify-monitor.armv7 -probe-runtime", nil
	case "enable-boot":
		return moduleNotifyInstallLinkCommand(), nil
	case "disable-boot":
		return moduleNotifyRemoveLinkCommand(), nil
	default:
		return "", errors.New("unknown module notification action")
	}
}

func moduleNotifyInstallLinkCommand() string {
	return "root_rw=0; restore_ro() { if test \"$root_rw\" = 1; then sync; mount -o remount,ro /; fi; }; " +
		"trap restore_ro EXIT HUP INT TERM; " +
		"if test -L '" + moduleNotifyInitLink + "'; then test \"$(readlink '" + moduleNotifyInitLink + "')\" = '" + moduleNotifyDir + "/start-on-boot.sh'; " +
		"else test ! -e '" + moduleNotifyInitLink + "' && mount -o remount,rw / && root_rw=1 && " +
		"ln -s '" + moduleNotifyDir + "/start-on-boot.sh' '" + moduleNotifyInitLink + "' && sync && mount -o remount,ro / && root_rw=0; fi && " +
		"test \"$(readlink '" + moduleNotifyInitLink + "')\" = '" + moduleNotifyDir + "/start-on-boot.sh'"
}

func moduleNotifyRemoveLinkCommand() string {
	return "root_rw=0; restore_ro() { if test \"$root_rw\" = 1; then sync; mount -o remount,ro /; fi; }; " +
		"trap restore_ro EXIT HUP INT TERM; " +
		"if test -L '" + moduleNotifyInitLink + "'; then test \"$(readlink '" + moduleNotifyInitLink + "')\" = '" + moduleNotifyDir + "/start-on-boot.sh' && " +
		"mount -o remount,rw / && root_rw=1 && rm -f '" + moduleNotifyInitLink + "' && sync && mount -o remount,ro / && root_rw=0; " +
		"else test ! -e '" + moduleNotifyInitLink + "'; fi"
}

func moduleNotifyRequiredKB(bytes int64) int64 { return (bytes+1023)/1024 + 1024 }

func moduleNotifyInstallPreflight(requiredKB int64) string {
	return `test "$(id -u)" = 0 && test -d /usrdata && test -r /usr/lib/libqmiservices.so.1 && ` +
		fmt.Sprintf(`test "$(df -k /usrdata | tail -n 1 | awk '{print $(NF-2)}')" -ge %d && `, requiredKB) +
		fmt.Sprintf("mkdir -p '%s' && chmod 700 '%s'", moduleNotifyDir, moduleNotifyDir)
}
