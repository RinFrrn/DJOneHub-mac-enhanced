//go:build darwin && cgo

package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// moduleADBInventoryCommand is deliberately a fixed, read-only command.  Do
// not expose arbitrary ADB shell input over the HTTP API: this endpoint exists
// only to identify the module's internal modem/control surfaces before a
// production iOS gateway is allowed to send call commands.
const moduleADBInventoryCommand = `
printf '%s\n' '--- id ---'
id -u 2>&1
printf '%s\n' '--- uname ---'
uname -a 2>&1
printf '%s\n' '--- device-nodes ---'
ls -l /dev/smd* /dev/ttyGS* /dev/qcqmi* /dev/ttyUSB* /dev/ttyHS* /dev/at* 2>&1 || true
printf '%s\n' '--- processes ---'
ps 2>&1 || true
printf '%s\n' '--- modem-process-fds ---'
for proc in /proc/[0-9]*; do
  cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)
  case "$cmd" in
    *atfwd*|*qmux*|*quectel*|*ril*|*gsmd*|*modem*)
      printf '%s %s\n' "$proc" "$cmd"
      ls -l "$proc"/fd 2>/dev/null | grep -E 'smd|at_usb|ttyHS|ttyHSL|ttyGS|qcqmi' || true
      ;;
  esac
done
printf '%s\n' '--- tty-drivers ---'
cat /proc/tty/drivers 2>&1
printf '%s\n' '--- tty-state ---'
cat /proc/tty/driver/smd 2>&1 || true
cat /proc/tty/driver/msm_serial_hs 2>&1 || true
cat /proc/tty/driver/msm_serial_hsl 2>&1 || true
printf '%s\n' '--- vendor-entrypoint-strings ---'
for binary in /usr/bin/atfwd_daemon /usr/bin/quectel_daemon /usr/bin/quectel-uart-ddp /usr/bin/qmuxd; do
  test -r "$binary" || continue
  printf '%s\n' "[$binary]"
  strings "$binary" 2>/dev/null | grep -Ei '/dev/|smd|at_usb|socket|at\\+|qmux|qmi' | sort -u | sed -n '1,120p' || true
done
printf '%s\n' '--- unix-sockets ---'
cat /proc/net/unix 2>&1 || true
true
`

func (a *app) moduleADBInventoryAPI(w http.ResponseWriter, _ *http.Request) {
	// ADB and the module voice helper share the same USB transport.  Serialize
	// this diagnostic with voice operations so a probe cannot claim the device
	// while a media route is being prepared or torn down.
	a.moduleVoiceOpMu.Lock()
	defer a.moduleVoiceOpMu.Unlock()

	adb, err := openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, "无法打开模块 ADB: "+err.Error())
		return
	}
	defer adb.Close()

	// shellChecked appends its own command terminator.  Trim the raw string so
	// BusyBox does not see a standalone `;` after a trailing newline.
	output, status, err := adb.shellChecked(
		strings.TrimSpace(moduleADBInventoryCommand), 15*time.Second,
	)
	if err != nil {
		// Preserve any bytes received before the shell transport failed.  This
		// is still read-only and makes BusyBox/firmware shell incompatibilities
		// diagnosable without adding an arbitrary command endpoint.
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error":     "模块 ADB 盘点失败: " + err.Error(),
			"inventory": strings.TrimSpace(output),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":    status,
		"inventory": strings.TrimSpace(output),
	})
}

type moduleQMIArtifact struct {
	archiveName string
	remotePath  string
	maxBytes    int
}

// moduleQMIArtifacts is a fixed allowlist.  The endpoint never accepts a
// module path from HTTP and never writes to the module; it only captures the
// exact vendor ABI needed to build a compatible QMI Voice client offline.
var moduleQMIArtifacts = []moduleQMIArtifact{
	{archiveName: "bin/quectel_daemon", remotePath: "/usr/bin/quectel_daemon", maxBytes: 16 << 20},
	{archiveName: "bin/atfwd_daemon", remotePath: "/usr/bin/atfwd_daemon", maxBytes: 16 << 20},
	{archiveName: "lib/libqmi_cci.so.1", remotePath: "/usr/lib/libqmi_cci.so.1", maxBytes: 16 << 20},
	{archiveName: "lib/libqmiidl.so.1", remotePath: "/usr/lib/libqmiidl.so.1", maxBytes: 16 << 20},
	{archiveName: "lib/libqmiservices.so.1", remotePath: "/usr/lib/libqmiservices.so.1", maxBytes: 32 << 20},
}

func (a *app) moduleADBQMIBundleAPI(w http.ResponseWriter, _ *http.Request) {
	a.moduleVoiceOpMu.Lock()
	defer a.moduleVoiceOpMu.Unlock()

	adb, err := openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, "无法打开模块 ADB: "+err.Error())
		return
	}
	defer adb.Close()

	var bundle bytes.Buffer
	zw := zip.NewWriter(&bundle)
	manifest := strings.Builder{}
	manifest.WriteString("DJOneHub QMI ABI bundle (read-only)\n")
	for _, artifact := range moduleQMIArtifacts {
		data, pullErr := adb.pull(artifact.remotePath, artifact.maxBytes, 30*time.Second)
		if pullErr != nil {
			_ = zw.Close()
			writeError(w, http.StatusBadGateway, "读取模块 QMI 组件失败 ("+artifact.remotePath+"): "+pullErr.Error())
			return
		}
		entry, createErr := zw.Create(artifact.archiveName)
		if createErr != nil {
			_ = zw.Close()
			writeError(w, http.StatusInternalServerError, "创建 QMI 盘点包失败: "+createErr.Error())
			return
		}
		if _, writeErr := entry.Write(data); writeErr != nil {
			_ = zw.Close()
			writeError(w, http.StatusInternalServerError, "写入 QMI 盘点包失败: "+writeErr.Error())
			return
		}
		digest := sha256.Sum256(data)
		fmt.Fprintf(&manifest, "%x  %s  %d bytes  source=%s\n", digest, artifact.archiveName, len(data), artifact.remotePath)
	}
	manifestEntry, err := zw.Create("MANIFEST.txt")
	if err != nil {
		_ = zw.Close()
		writeError(w, http.StatusInternalServerError, "创建 QMI 清单失败: "+err.Error())
		return
	}
	if _, err = manifestEntry.Write([]byte(manifest.String())); err != nil {
		_ = zw.Close()
		writeError(w, http.StatusInternalServerError, "写入 QMI 清单失败: "+err.Error())
		return
	}
	if err = zw.Close(); err != nil {
		writeError(w, http.StatusInternalServerError, "完成 QMI 盘点包失败: "+err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="djonehub-qmi-abi.zip"`)
	w.Header().Set("Content-Length", fmt.Sprintf("%d", bundle.Len()))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(bundle.Bytes())
}
