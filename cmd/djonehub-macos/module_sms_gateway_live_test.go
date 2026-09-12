//go:build darwin && cgo

package main

import (
	"os"
	"testing"
	"time"
)

// This test is intentionally opt-in: it talks to the attached QDC507 over
// the repository's libusb ADB transport and therefore briefly interrupts the
// sibling ECM interface.  It is useful when qualifying a new module image.
func TestLiveQDC507ShellCapabilities(t *testing.T) {
	if os.Getenv("DJONEHUB_LIVE_QDC507") != "1" {
		t.Skip("set DJONEHUB_LIVE_QDC507=1 with a QDC507 attached")
	}
	adb, err := openDJIUSBADB()
	if err != nil {
		t.Fatal(err)
	}
	defer adb.Close()
	out, status, err := adb.shellChecked(
		"printf 'nohup='; command -v nohup 2>/dev/null || echo absent; "+
			"printf 'setsid='; command -v setsid 2>/dev/null || echo absent; "+
			"echo launch_log_begin; test ! -f /tmp/djonehub-session-launch.log || cat /tmp/djonehub-session-launch.log; echo launch_log_end",
		8*time.Second,
	)
	if err != nil || status != 0 {
		t.Fatalf("shell capability probe failed: status=%d err=%v output=%q", status, err, out)
	}
	t.Log(sentinelCleanShellOutput(out))
}

func TestLiveQDC507SMSGateway(t *testing.T) {
	if os.Getenv("DJONEHUB_LIVE_QDC507") != "1" {
		t.Skip("set DJONEHUB_LIVE_QDC507=1 with a QDC507 attached")
	}
	keyPath, err := stableDevelopmentControlKeyPath()
	if err != nil {
		t.Fatal(err)
	}
	key, err := readStableDevelopmentControlKey(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		for index := range key {
			key[index] = 0
		}
	}()
	status, err := queryTemporarySMSGateway(key)
	if err != nil {
		t.Fatal(err)
	}
	if status.Status != 0 {
		t.Fatalf("STATUS returned gateway status %d: %+v", status.Status, status)
	}
	nv, err := queryTemporarySMSGatewayList(key, 1)
	if err != nil {
		t.Fatal(err)
	}
	sim, err := queryTemporarySMSGatewayList(key, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("status=%+v nv=%+v sim=%+v", status, nv, sim)
	if nv.Status != 0 || sim.Status != 0 {
		t.Fatalf("LIST failed: nv=%+v sim=%+v", nv, sim)
	}
}
