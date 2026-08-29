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
	qmiVoiceProbeExpectedSHA256 = "440463eed6ccd0185e5d9eb16b2dce466b2c079a2f7d4a4fc03fb106461f95a6"
	qmiVoiceProbeRemotePath     = "/tmp/djonehub-qmi-probe.armv7"
	qmiVoiceProbeMaximumSize    = 2 * 1024 * 1024
)

func defaultQMIVoiceProbeArtifactPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	downloads := filepath.Join(home, "Downloads")
	fallback := filepath.Join(downloads, "djonehubd-armv7-sentinel", "djonehub-qmi-probe.armv7")
	matches, err := filepath.Glob(filepath.Join(downloads, "djonehubd-armv7-sentinel*", "djonehub-qmi-probe.armv7"))
	if err != nil {
		return fallback
	}
	for _, path := range matches {
		data, readErr := os.ReadFile(path)
		if readErr == nil && validateQMIVoiceProbeArtifact(data) == nil {
			return path
		}
	}
	return fallback
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
	// The QDC507 loader predates modern PIE layouts. The probe intentionally
	// uses a dynamically linked ET_EXEC layout with 4 KiB page alignment.
	if binary.LittleEndian.Uint16(data[16:18]) != 2 {
		return errors.New("QMI Voice 探针不是 ET_EXEC 动态可执行文件")
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
