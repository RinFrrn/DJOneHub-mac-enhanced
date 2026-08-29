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
)

const (
	qmiVoiceProbeExpectedSHA256 = "89eafb52a94272b21e5679257e6ff8c3e168111ec6d55f2db52b59a8554be8d5"
	qmiVoiceProbeRemotePath     = "/tmp/djonehub-qmi-probe.armv7"
	qmiVoiceProbeMaximumSize    = 2 * 1024 * 1024
)

func defaultQMIVoiceProbeArtifactPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Downloads", "djonehubd-armv7-sentinel-3", "djonehub-qmi-probe.armv7")
}

func validateQMIVoiceProbeELF(data []byte) error {
	if len(data) < 52 || !bytes.Equal(data[:4], sentinelELFMagic) {
		return errors.New("QMI Voice 探针不是 ELF 可执行文件")
	}
	if data[4] != 1 {
		return errors.New("QMI Voice 探针不是 ELF32")
	}
	if data[5] != 1 {
		return errors.New("QMI Voice 探针不是小端序 ELF")
	}
	// The probe is a position-independent dynamic executable (ET_DYN).
	if binary.LittleEndian.Uint16(data[16:18]) != 3 {
		return errors.New("QMI Voice 探针不是 ET_DYN PIE 可执行文件")
	}
	if binary.LittleEndian.Uint16(data[18:20]) != 40 {
		return errors.New("QMI Voice 探针不是 ARM 可执行文件")
	}
	return nil
}

func validateQMIVoiceProbeArtifact(data []byte) error {
	if len(data) == 0 || len(data) > qmiVoiceProbeMaximumSize {
		return fmt.Errorf("QMI Voice 探针文件大小无效：%d bytes", len(data))
	}
	if err := validateQMIVoiceProbeELF(data); err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	actual := hex.EncodeToString(sum[:])
	if actual != qmiVoiceProbeExpectedSHA256 {
		return fmt.Errorf("QMI Voice 探针 SHA-256 不匹配：需要 %s，实际 %s", qmiVoiceProbeExpectedSHA256, actual)
	}
	return nil
}
