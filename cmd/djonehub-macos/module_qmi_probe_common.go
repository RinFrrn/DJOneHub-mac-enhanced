package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
)

const (
	qmiVoiceProbeExpectedSHA256 = "440463eed6ccd0185e5d9eb16b2dce466b2c079a2f7d4a4fc03fb106461f95a6"
	qmiVoiceProbeRemotePath     = "/tmp/djonehub-qmi-probe.armv7"
	qmiVoiceControlExpectedSHA256 = "86922281bc2eb5b52eaa7e272adba4fe1eb0d824556fa1d9e5f835edd5508667"
	qmiVoiceControlRemotePath     = "/tmp/djonehub-qmi-voice-control.armv7"
	qmiVoiceProbeMaximumSize    = 2 * 1024 * 1024
)

func defaultPinnedQMIArtifactPath(filename string, _ func([]byte) error) string {
	// LaunchAgents can block indefinitely when macOS asks them to access a
	// quarantined Downloads item without an interactive TCC presentation.  The
	// terminal-side installer validates and stages artifacts in Application
	// Support; the backend still enforces its independently pinned SHA-256.
	return defaultModuleArtifactPath(filename)
}

func defaultQMIVoiceProbeArtifactPath() string {
	return defaultPinnedQMIArtifactPath("djonehub-qmi-probe.armv7", validateQMIVoiceProbeArtifact)
}

func defaultQMIVoiceControlArtifactPath() string {
	return defaultPinnedQMIArtifactPath("djonehub-qmi-voice-control.armv7", validateQMIVoiceControlArtifact)
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

func validateQMIVoiceControlArtifact(data []byte) error {
	if len(data) == 0 || len(data) > qmiVoiceProbeMaximumSize {
		return fmt.Errorf("QMI Voice 控制候选文件大小无效：%d bytes", len(data))
	}
	if err := validateQMIVoiceProbeELF(data); err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	actual := hex.EncodeToString(sum[:])
	if actual != qmiVoiceControlExpectedSHA256 {
		return fmt.Errorf("QMI Voice 控制候选 SHA-256 不匹配：需要 %s，实际 %s", qmiVoiceControlExpectedSHA256, actual)
	}
	return nil
}

func validQMIVoiceDialNumber(number string) bool {
	if len(number) == 0 || len(number) > 81 {
		return false
	}
	hasDigit := false
	for index := 0; index < len(number); index++ {
		character := number[index]
		if character >= '0' && character <= '9' {
			hasDigit = true
			continue
		}
		if character == '*' || character == '#' {
			continue
		}
		if character != '+' || index != 0 {
			return false
		}
	}
	return hasDigit
}

func validQMIVoiceCallID(callID int) bool {
	return callID >= 1 && callID <= 255
}
