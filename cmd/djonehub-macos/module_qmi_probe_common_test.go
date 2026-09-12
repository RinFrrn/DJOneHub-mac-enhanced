package main

import (
	"encoding/binary"
	"strings"
	"testing"
)

func qmiVoiceProbeTestELF(kind uint16, machine uint16) []byte {
	data := make([]byte, 52)
	copy(data[:4], sentinelELFMagic)
	data[4] = 1
	data[5] = 1
	binary.LittleEndian.PutUint16(data[16:18], kind)
	binary.LittleEndian.PutUint16(data[18:20], machine)
	return data
}

func TestValidateQMIVoiceProbeELF(t *testing.T) {
	if err := validateQMIVoiceProbeELF(qmiVoiceProbeTestELF(2, 40)); err != nil {
		t.Fatalf("valid ELF rejected: %v", err)
	}
	cases := []struct {
		name string
		data []byte
		want string
	}{
		{"not ELF", []byte("no"), "不是 ELF"},
		{"not executable", qmiVoiceProbeTestELF(3, 40), "ET_EXEC"},
		{"not ARM", qmiVoiceProbeTestELF(2, 62), "不是 ARM"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateQMIVoiceProbeELF(tc.data)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("got %v, want error containing %q", err, tc.want)
			}
		})
	}
}

func TestValidateQMIVoiceProbeArtifactRejectsUnpinnedBinary(t *testing.T) {
	err := validateQMIVoiceProbeArtifact(qmiVoiceProbeTestELF(2, 40))
	if err == nil || !strings.Contains(err.Error(), "SHA-256 不匹配") {
		t.Fatalf("got %v, want pinned hash rejection", err)
	}
}

func TestValidateQMIVoiceControlArtifactRejectsUnpinnedBinary(t *testing.T) {
	err := validateQMIVoiceControlArtifact(qmiVoiceProbeTestELF(2, 40))
	if err == nil || !strings.Contains(err.Error(), "SHA-256 不匹配") {
		t.Fatalf("got %v, want pinned hash rejection", err)
	}
}

func TestValidQMIVoiceDialNumber(t *testing.T) {
	valid := []string{"1", "+8613800138000", "*123#"}
	invalid := []string{"", "+", "1+2", "12 34", "12;reboot", strings.Repeat("1", 82)}
	for _, number := range valid {
		if !validQMIVoiceDialNumber(number) {
			t.Fatalf("valid number rejected: %q", number)
		}
	}
	for _, number := range invalid {
		if validQMIVoiceDialNumber(number) {
			t.Fatalf("invalid number accepted: %q", number)
		}
	}
}

func TestValidQMIVoiceCallID(t *testing.T) {
	for _, callID := range []int{1, 127, 255} {
		if !validQMIVoiceCallID(callID) {
			t.Fatalf("valid call ID rejected: %d", callID)
		}
	}
	for _, callID := range []int{-1, 0, 256} {
		if validQMIVoiceCallID(callID) {
			t.Fatalf("invalid call ID accepted: %d", callID)
		}
	}
}
