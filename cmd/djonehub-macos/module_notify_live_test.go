//go:build darwin && cgo

package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/iniwex5/vohive/internal/modulepush"
)

// Opt-in, temporary deployment only. Uses the project's USB ADB transport;
// system adb may not list this vendor interface. Never modifies boot scripts,
// call state, audio routing, pairing keys or SMS storage. Raw PDUs are parsed
// locally, never printed in test output.
func TestLiveQDC507NotifyRuntime(t *testing.T) {
	if os.Getenv("DJONEHUB_LIVE_NOTIFY") != "1" {
		t.Skip("set DJONEHUB_LIVE_NOTIFY=1 with idle QDC507 attached")
	}
	artifactDir := os.Getenv("DJONEHUB_NOTIFY_ARTIFACT_DIR")
	if artifactDir == "" {
		artifactDir = "../../outputs/module"
	}
	adb, err := openDJIUSBADB()
	if err != nil {
		t.Fatal(err)
	}
	defer adb.Close()
	if err := sentinelRequireRoot(adb); err != nil {
		t.Fatal(err)
	}
	resources, resourceStatus, resourceErr := adb.shellChecked(`df -k /usrdata /tmp; sed -n '1,8p' /proc/meminfo; date -u`, 8*time.Second)
	if resourceErr != nil || resourceStatus != 0 {
		t.Fatal("cannot read module resource budget", resourceErr)
	}
	t.Log(sentinelCleanShellOutput(resources))
	// Large static Go artifacts must not consume the module's RAM-backed /tmp.
	var totalBytes int64
	for _, name := range []string{"djonehub-notify.armv7", "djonehub-notify-monitor.armv7"} {
		info, err := os.Stat(filepath.Join(artifactDir, name))
		if err != nil {
			t.Fatal(err)
		}
		totalBytes += info.Size()
	}
	if err := sentinelShell(adb, fmt.Sprintf(`test "$(df -k /usrdata | tail -n 1 | awk '{print $(NF-2)}')" -ge %d`, moduleNotifyRequiredKB(totalBytes)+(512)), 5*time.Second); err != nil {
		t.Fatal("insufficient /usrdata space", err)
	}
	remote := fmt.Sprintf("/usrdata/djonehub-notify-probe-%d", time.Now().UnixNano())
	t.Logf("temporary probe directory: %s", remote)
	if err := sentinelShell(adb, "mkdir -m 700 '"+remote+"'", 5*time.Second); err != nil {
		t.Fatal(err)
	}
	defer func() {
		adb.connected = false
		if err := sentinelShell(adb, "rm -rf '"+remote+"'", 10*time.Second); err != nil {
			t.Error("temporary probe cleanup failed", err)
		}
	}()
	for _, name := range []string{"djonehub-notify.armv7", "djonehub-notify-monitor.armv7"} {
		data, err := os.ReadFile(filepath.Join(artifactDir, name))
		if err != nil {
			t.Fatal(err)
		}
		if err := adb.push(data, remote+"/"+name, 0100700, 90*time.Second); err != nil {
			t.Fatal("artifact upload failed", err)
		}
		digest := sha256.Sum256(data)
		// Old adbd can leave a trailing sync packet; establish a fresh session
		// before returning to shell rather than interpreting it as a new stream.
		adb.connected = false
		command := fmt.Sprintf("chmod 700 '%s/%s' && test \"$(sha256sum '%s/%s' | cut -d ' ' -f 1)\" = '%x'", remote, name, remote, name, digest)
		if err := sentinelShell(adb, command, 10*time.Second); err != nil {
			t.Fatal("artifact verification failed", err)
		}
	}
	for _, mode := range []string{"--calls", "--sms"} {
		out, status, err := adb.shellChecked("LD_LIBRARY_PATH=/usr/lib "+remote+"/djonehub-notify-monitor.armv7 "+mode+" --once", 45*time.Second)
		if err != nil || status != 0 {
			t.Fatalf("native monitor %s failed: status=%d err=%v", mode, status, err)
		}
		frames := 0
		for _, line := range strings.Split(sentinelCleanShellOutput(out), "\n") {
			if !strings.HasPrefix(line, "{") {
				continue
			}
			var event modulepush.Snapshot
			if json.Unmarshal([]byte(line), &event) != nil {
				t.Fatal("invalid module snapshot")
			}
			if _, err := modulepush.NewState().Apply(event, modulepush.EventOptions{}, time.Now()); err != nil {
				t.Fatal("invalid module snapshot content", err)
			}
			t.Logf("native QMI snapshot: kind=%s storage=%d calls=%d SMS_PDUs=%d", event.Kind, event.Storage, len(event.Calls), len(event.PDUs))
			frames++
		}
		expected := 1
		if mode == "--sms" {
			expected = 2
		}
		if frames != expected {
			t.Fatalf("monitor %s returned %d of %d complete snapshots", mode, frames, expected)
		}
	}
	output, status, err := adb.shellChecked("ulimit -c 0; GOMEMLIMIT=6MiB GOGC=25 GOMAXPROCS=1 "+remote+"/djonehub-notify.armv7 -init -config "+remote+"/config.json", 15*time.Second)
	if err != nil || status != 0 || !strings.Contains(output, "Saved private config") {
		t.Fatalf("native Go startup failed: status=%d err=%v output=%s", status, err, sentinelCleanShellOutput(output))
	}
	t.Log("native ARM sender started and generated per-module VAPID keys")
	output, status, err = adb.shellChecked("ulimit -c 0; GOMEMLIMIT=6MiB GOGC=25 GOMAXPROCS=1 LD_LIBRARY_PATH=/usr/lib "+remote+"/djonehub-notify.armv7 -probe-runtime -config "+remote+"/config.json -monitor "+remote+"/djonehub-notify-monitor.armv7", 45*time.Second)
	if err != nil || status != 0 {
		t.Fatalf("native runtime probe failed: status=%d err=%v output=%s", status, err, sentinelCleanShellOutput(output))
	}
	t.Log(sentinelCleanShellOutput(output))
	if caFile := os.Getenv("DJONEHUB_NOTIFY_CA_FILE"); caFile != "" {
		data, err := os.ReadFile(caFile)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), "BEGIN CERTIFICATE") || strings.Contains(string(data), "PRIVATE KEY") {
			t.Fatal("expected public CA certificate bundle")
		}
		if err := adb.push(data, remote+"/ca.pem", 0100600, 30*time.Second); err != nil {
			t.Fatal(err)
		}
		adb.connected = false
		out, status, err := adb.shellChecked("ulimit -c 0; GOMEMLIMIT=6MiB GOGC=25 GOMAXPROCS=1 SSL_CERT_FILE="+remote+"/ca.pem "+remote+"/djonehub-notify.armv7 -probe-network", 25*time.Second)
		if err != nil || status != 0 {
			t.Fatalf("TLS probe failed: status=%d err=%v output=%s", status, err, sentinelCleanShellOutput(out))
		}
		t.Log(sentinelCleanShellOutput(out))
	}
}

// Recovery is confined to directories created by this probe. A small tmpfs can
// accept the static Go binary but leave too little memory for adbd to fork a
// shell. ADB sync can truncate our own artifact without spawning a shell.
func TestLiveQDC507NotifyProbeCleanup(t *testing.T) {
	if os.Getenv("DJONEHUB_NOTIFY_PROBE_CLEANUP") != "1" {
		t.Skip("opt-in probe cleanup")
	}
	adb, err := openDJIUSBADB()
	if err != nil {
		t.Fatal(err)
	}
	defer adb.Close()
	names, err := notifyProbeDirectories(adb)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range names {
		remote := "/tmp/" + name
		adb.connected = false
		if err := adb.push(nil, remote+"/djonehub-notify.armv7", 0100600, 10*time.Second); err != nil {
			t.Fatal("cannot release probe tmpfs allocation", err)
		}
		adb.connected = false
		if err := sentinelShell(adb, "rm -rf '"+remote+"'", 10*time.Second); err != nil {
			t.Fatal("cannot clean probe directory", err)
		}
		t.Log("removed temporary probe directory", name)
	}
}

func notifyProbeDirectories(adb *adbClient) ([]string, error) {
	adb.mu.Lock()
	defer adb.mu.Unlock()
	if err := adb.connectLocked(); err != nil {
		return nil, err
	}
	stream, err := adb.openServiceLocked("sync:")
	if err != nil {
		return nil, err
	}
	defer adb.closeStreamLocked(stream)
	deadline := time.Now().Add(10 * time.Second)
	if err := adb.writeSyncLocked(stream, "LIST", []byte("/tmp"), deadline); err != nil {
		return nil, err
	}
	var data []byte
	var names []string
	for time.Now().Before(deadline) {
		msg, err := adb.receiveLocked(deadline)
		if err != nil {
			return nil, err
		}
		if msg.command != 0x45545257 || msg.arg0 != stream.remoteID || msg.arg1 != stream.localID {
			continue
		}
		data = append(data, msg.payload...)
		if err := adb.sendLocked(0x59414b4f, stream.localID, stream.remoteID, nil, 2*time.Second); err != nil {
			return nil, err
		}
		for len(data) >= 20 {
			if string(data[:4]) == "DONE" {
				return names, nil
			}
			if string(data[:4]) != "DENT" {
				return nil, fmt.Errorf("unexpected sync listing frame")
			}
			size := int(binary.LittleEndian.Uint32(data[16:20]))
			if size > 1024 {
				return nil, fmt.Errorf("invalid sync filename length")
			}
			if len(data) < 20+size {
				break
			}
			name := string(data[20 : 20+size])
			if strings.HasPrefix(name, "djonehub-notify-probe-") {
				suffix := strings.TrimPrefix(name, "djonehub-notify-probe-")
				if len(suffix) > 0 && strings.Trim(suffix, "0123456789") == "" {
					names = append(names, name)
				}
			}
			data = data[20+size:]
		}
	}
	return nil, fmt.Errorf("sync listing timed out")
}
