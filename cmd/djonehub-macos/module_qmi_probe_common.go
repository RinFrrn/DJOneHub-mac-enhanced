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
	qmiVoiceProbeExpectedSHA256 = "2e77e9a08bb139f522235c04e25f38551b543054fb029735e1f017918f86ec27"
	qmiVoiceProbeRemotePath     = "/tmp/djonehub-qmi-probe.armv7"
	qmiVoiceProbeMaximumSize    = 2 * 1024 * 1024
)

func defaultQMIVoiceProbeArtifactPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Downloads", "djonehubd-armv7-sentinel-4", "djonehub-qmi-probe.armv7")
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
