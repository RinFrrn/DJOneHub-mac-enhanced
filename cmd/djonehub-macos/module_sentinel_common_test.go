package main

import (
	"encoding/binary"
	"strings"
	"testing"
)

func testSentinelELF() []byte {
	data := make([]byte, 52)
	copy(data[:4], sentinelELFMagic)
	data[4] = 1
	data[5] = 1
	binary.LittleEndian.PutUint16(data[16:18], 2)
	binary.LittleEndian.PutUint16(data[18:20], 40)
	return data
}

func TestValidateSentinelELF(t *testing.T) {
	if err := validateSentinelELF(testSentinelELF()); err != nil {
		t.Fatalf("valid ARM ELF rejected: %v", err)
	}
}

func TestValidateSentinelELFRejectsWrongArchitecture(t *testing.T) {
	data := testSentinelELF()
	binary.LittleEndian.PutUint16(data[18:20], 62)
	if err := validateSentinelELF(data); err == nil || !strings.Contains(err.Error(), "ARM") {
		t.Fatalf("wrong architecture error = %v", err)
	}
}

func TestValidateSentinelArtifactRejectsUnknownHash(t *testing.T) {
	if err := validateSentinelArtifact(testSentinelELF()); err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("unknown artifact error = %v", err)
	}
}

func TestSentinelStartScriptIsOneShot(t *testing.T) {
	for _, required := range []string{
		`test -f "$marker" || exit 0`,
		`rm -f "$marker"`,
		`--listen-address 192.168.225.1 --port 45750`,
	} {
		if !strings.Contains(sentinelStartOnceScript, required) {
			t.Fatalf("start script missing %q", required)
		}
	}
}

func TestSentinelCleanShellOutput(t *testing.T) {
	raw := "0\n\n__MAVO_STATUS_abc_0__\n"
	if got := sentinelCleanShellOutput(raw); got != "0" {
		t.Fatalf("clean shell output = %q", got)
	}
}

func TestSentinelLinkCommandsFailClosed(t *testing.T) {
	verification := "test \"$(readlink '" + sentinelInitLink + "')\" = '" + sentinelRemoteScript + "'"
	for name, command := range map[string]string{
		"install": sentinelInstallLinkCommand(),
		"remove":  sentinelRemoveLinkCommand(),
	} {
		if !strings.Contains(command, verification+" && ") {
			t.Errorf("%s command does not chain link verification with &&", name)
		}
		if strings.Contains(command, verification+"; ") {
			t.Errorf("%s command can mask a failed link verification", name)
		}
		if !strings.Contains(command, "mount -o remount,ro / && root_rw=0") {
			t.Errorf("%s command does not verify the read-only remount", name)
		}
	}
}
