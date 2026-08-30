package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	sentinelExpectedSHA256 = "1b3342522893795430a77f9b5cd9c65e2ea67e0d1e970665bbac98f34c06d19a"
	sentinelRemoteDir      = "/usrdata/djonehub/sentinel"
	sentinelRemoteBinary   = sentinelRemoteDir + "/djonehubd.armv7"
	sentinelRemoteScript   = sentinelRemoteDir + "/start-once.sh"
	sentinelRemoteMarker   = sentinelRemoteDir + "/run-once"
	sentinelBootStateFile  = sentinelRemoteDir + "/last-start.state"
	sentinelBootLogFile    = sentinelRemoteDir + "/last-start.log"
	sentinelInitLink       = "/etc/rc5.d/S98djonehub-sentinel"
	sentinelPIDFile        = "/run/djonehub-sentinel.pid"
	sentinelLogFile        = "/tmp/djonehub-sentinel.log"
	sentinelMaximumSize    = 2 * 1024 * 1024
)

var sentinelELFMagic = []byte{0x7f, 'E', 'L', 'F'}

func sentinelCleanShellOutput(output string) string {
	lines := strings.Split(output, "\n")
	kept := lines[:0]
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "__MAVO_STATUS_") && strings.HasSuffix(trimmed, "__") {
			continue
		}
		kept = append(kept, line)
	}
	return strings.TrimSpace(strings.Join(kept, "\n"))
}

func sentinelInstallLinkCommand() string {
	return "root_rw=0; " +
		"restore_ro() { if test \"$root_rw\" = 1; then sync; mount -o remount,ro /; fi; }; " +
		"trap restore_ro EXIT HUP INT TERM; " +
		"mount -o remount,rw / && root_rw=1 && " +
		"test ! -e '" + sentinelInitLink + "' && test ! -L '" + sentinelInitLink + "' && " +
		"ln -s '" + sentinelRemoteScript + "' '" + sentinelInitLink + "' && " +
		"sync && mount -o remount,ro / && root_rw=0 && " +
		"test \"$(readlink '" + sentinelInitLink + "')\" = '" + sentinelRemoteScript + "' && " +
		"awk '$2 == \"/\" && $4 ~ /(^|,)ro(,|$)/ { found=1 } END { exit found ? 0 : 1 }' /proc/mounts"
}

func sentinelRemoveLinkCommand() string {
	return "root_rw=0; " +
		"restore_ro() { if test \"$root_rw\" = 1; then sync; mount -o remount,ro /; fi; }; " +
		"trap restore_ro EXIT HUP INT TERM; " +
		"mount -o remount,rw / && root_rw=1 && " +
		"test \"$(readlink '" + sentinelInitLink + "')\" = '" + sentinelRemoteScript + "' && " +
		"rm -f '" + sentinelInitLink + "' && sync && " +
		"mount -o remount,ro / && root_rw=0 && test ! -e '" + sentinelInitLink + "' && " +
		"awk '$2 == \"/\" && $4 ~ /(^|,)ro(,|$)/ { found=1 } END { exit found ? 0 : 1 }' /proc/mounts"
}

func defaultSentinelArtifactPath() string {
	return defaultModuleArtifactPath("djonehubd.armv7")
}

func defaultModuleArtifactPath(filename string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "DJOneHub", "artifacts", filename)
}

func validateSentinelELF(data []byte) error {
	if len(data) < 52 || !bytes.Equal(data[:4], sentinelELFMagic) {
		return errors.New("文件不是 ELF 可执行文件")
	}
	if data[4] != 1 {
		return errors.New("sentinel 不是 ELF32")
	}
	if data[5] != 1 {
		return errors.New("sentinel 不是小端序 ELF")
	}
	if binary.LittleEndian.Uint16(data[16:18]) != 2 {
		return errors.New("sentinel 不是 ET_EXEC 可执行文件")
	}
	if binary.LittleEndian.Uint16(data[18:20]) != 40 {
		return errors.New("sentinel 不是 ARM 可执行文件")
	}
	return nil
}

func validateSentinelArtifact(data []byte) error {
	if len(data) == 0 || len(data) > sentinelMaximumSize {
		return fmt.Errorf("sentinel 文件大小无效：%d bytes", len(data))
	}
	if err := validateSentinelELF(data); err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	actual := hex.EncodeToString(sum[:])
	if actual != sentinelExpectedSHA256 {
		return fmt.Errorf("sentinel SHA-256 不匹配：需要 %s，实际 %s", sentinelExpectedSHA256, actual)
	}
	return nil
}

const sentinelStartOnceScript = `#!/bin/sh
base=/usrdata/djonehub/sentinel
binary="$base/djonehubd.armv7"
marker="$base/run-once"
state="$base/last-start.state"
log="$base/last-start.log"
pidfile=/run/djonehub-sentinel.pid

test -f "$marker" || exit 0
rm -f "$marker"
printf 'marker-consumed\n' >"$state"
{
    echo 'djonehub sentinel: one-shot marker consumed'
    printf 'uptime='; cat /proc/uptime 2>/dev/null || true
} >"$log"
sync

(
    attempt=0
    while test "$attempt" -lt 60; do
        if ip addr show 2>/dev/null | grep -q 'inet 192\.168\.225\.1/'; then
            printf 'listener-starting\n' >"$state"
            echo 'djonehub sentinel: 192.168.225.1 ready; starting listener'
            ip addr show 2>/dev/null || true
            exec "$binary" --listen-address 192.168.225.1 --port 45750
            result=$?
            printf 'exec-failed:%s\n' "$result" >"$state"
            echo "djonehub sentinel: listener exec failed: $result"
            exit "$result"
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    printf 'address-timeout\n' >"$state"
    echo 'djonehub sentinel: 192.168.225.1 did not appear on any interface'
    ip addr show 2>/dev/null || true
    cat /proc/net/dev 2>/dev/null || true
) >>"$log" 2>&1 &
echo "$!" >"$pidfile"
exit 0
`
