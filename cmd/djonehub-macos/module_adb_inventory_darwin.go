//go:build darwin && cgo

package main

import (
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
printf '%s\n' '--- tty-drivers ---'
cat /proc/tty/drivers 2>&1
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
