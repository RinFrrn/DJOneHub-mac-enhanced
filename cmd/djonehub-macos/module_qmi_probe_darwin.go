//go:build darwin && cgo

package main

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type qmiVoiceProbeRequest struct {
	Confirm      bool   `json:"confirm"`
	ArtifactPath string `json:"artifact_path"`
}

func loadQMIVoiceProbeArtifact(path string) ([]byte, string, error) {
	if strings.TrimSpace(path) == "" {
		path = defaultQMIVoiceProbeArtifactPath()
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, "", fmt.Errorf("无法解析 QMI Voice 探针路径: %w", err)
	}
	info, err := os.Lstat(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("无法读取 QMI Voice 探针: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, "", errors.New("QMI Voice 探针必须是普通文件，不能是符号链接")
	}
	if info.Size() <= 0 || info.Size() > qmiVoiceProbeMaximumSize {
		return nil, "", fmt.Errorf("QMI Voice 探针文件大小无效：%d bytes", info.Size())
	}
	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("读取 QMI Voice 探针失败: %w", err)
	}
	if err := validateQMIVoiceProbeArtifact(data); err != nil {
		return nil, "", err
	}
	return data, absPath, nil
}

func loadQMIVoiceControlArtifact(path string) ([]byte, string, error) {
	if strings.TrimSpace(path) == "" {
		path = defaultQMIVoiceControlArtifactPath()
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, "", fmt.Errorf("无法解析 QMI Voice 控制候选路径: %w", err)
	}
	info, err := os.Lstat(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("无法读取 QMI Voice 控制候选: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, "", errors.New("QMI Voice 控制候选必须是普通文件，不能是符号链接")
	}
	if info.Size() <= 0 || info.Size() > qmiVoiceProbeMaximumSize {
		return nil, "", fmt.Errorf("QMI Voice 控制候选文件大小无效：%d bytes", info.Size())
	}
	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("读取 QMI Voice 控制候选失败: %w", err)
	}
	if err := validateQMIVoiceControlArtifact(data); err != nil {
		return nil, "", err
	}
	return data, absPath, nil
}

func (a *app) qmiVoiceProbeAPI(w http.ResponseWriter, r *http.Request) {
	var request qmiVoiceProbeRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm {
		writeError(w, http.StatusBadRequest, "需要明确确认运行只读 QMI Voice 探针")
		return
	}
	data, artifactPath, err := loadQMIVoiceProbeArtifact(request.ArtifactPath)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	a.moduleVoiceOpMu.Lock()
	defer a.moduleVoiceOpMu.Unlock()
	adb, err := openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, "无法打开模块 ADB: "+err.Error())
		return
	}
	defer adb.Close()
	if err := sentinelRequireRoot(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	// Never leave a previous probe behind. The fixed path and fixed digest also
	// prevent this endpoint from becoming a general-purpose executable runner.
	_, _, _ = adb.shellChecked("rm -f '"+qmiVoiceProbeRemotePath+"'", 8*time.Second)
	if err := adb.pushContext(r.Context(), data, qmiVoiceProbeRemotePath, 0o100700, 30*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "推送 QMI Voice 探针失败: "+err.Error())
		return
	}
	defer func() {
		if _, _, cleanupErr := adb.shellChecked("rm -f '"+qmiVoiceProbeRemotePath+"'", 8*time.Second); cleanupErr != nil {
			log.Printf("QMI Voice probe cleanup failed: %v", cleanupErr)
		}
	}()

	verifyAndRun := "chmod 700 '" + qmiVoiceProbeRemotePath + "' && " +
		"test \"$(sha256sum '" + qmiVoiceProbeRemotePath + "' | awk '{print $1}')\" = '" + qmiVoiceProbeExpectedSHA256 + "' && " +
		"LD_LIBRARY_PATH=/usr/lib '" + qmiVoiceProbeRemotePath + "' 2>&1"
	output, status, runErr := adb.shellChecked(verifyAndRun, 20*time.Second)
	cleanOutput := sentinelCleanShellOutput(output)
	if runErr != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error":         "运行 QMI Voice 探针失败: " + runErr.Error(),
			"output":        cleanOutput,
			"artifact_path": artifactPath,
			"sha256":        qmiVoiceProbeExpectedSHA256,
			"persistent":    false,
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"compatible":    status == 0,
		"exit_status":   status,
		"output":        cleanOutput,
		"artifact_path": artifactPath,
		"sha256":        qmiVoiceProbeExpectedSHA256,
		"remote_path":   qmiVoiceProbeRemotePath,
		"persistent":    false,
	})
}

func (a *app) qmiVoiceControlStatusAPI(w http.ResponseWriter, r *http.Request) {
	var request qmiVoiceProbeRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm {
		writeError(w, http.StatusBadRequest, "需要明确确认运行 QMI Voice 控制候选的只读 status 子命令")
		return
	}
	data, artifactPath, err := loadQMIVoiceControlArtifact(request.ArtifactPath)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	a.moduleVoiceOpMu.Lock()
	defer a.moduleVoiceOpMu.Unlock()
	adb, err := openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, "无法打开模块 ADB: "+err.Error())
		return
	}
	defer adb.Close()
	if err := sentinelRequireRoot(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	// The command is a literal "status". No request field can select dial,
	// answer, end, a call ID, a number, or an arbitrary shell/QMI argument.
	_, _, _ = adb.shellChecked("rm -f '"+qmiVoiceControlRemotePath+"'", 8*time.Second)
	if err := adb.pushContext(r.Context(), data, qmiVoiceControlRemotePath, 0o100700, 30*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "推送 QMI Voice 控制候选失败: "+err.Error())
		return
	}
	defer func() {
		if _, _, cleanupErr := adb.shellChecked("rm -f '"+qmiVoiceControlRemotePath+"'", 8*time.Second); cleanupErr != nil {
			log.Printf("QMI Voice control candidate cleanup failed: %v", cleanupErr)
		}
	}()

	verifyAndRun := "chmod 700 '" + qmiVoiceControlRemotePath + "' && " +
		"test \"$(sha256sum '" + qmiVoiceControlRemotePath + "' | awk '{print $1}')\" = '" + qmiVoiceControlExpectedSHA256 + "' && " +
		"LD_LIBRARY_PATH=/usr/lib '" + qmiVoiceControlRemotePath + "' status 2>&1"
	output, status, runErr := adb.shellChecked(verifyAndRun, 20*time.Second)
	cleanOutput := sentinelCleanShellOutput(output)
	if runErr != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error":         "运行 QMI Voice 控制候选 status 失败: " + runErr.Error(),
			"output":        cleanOutput,
			"artifact_path": artifactPath,
			"sha256":        qmiVoiceControlExpectedSHA256,
			"persistent":    false,
			"operation":     "status",
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"compatible":    status == 0,
		"exit_status":   status,
		"output":        cleanOutput,
		"artifact_path": artifactPath,
		"sha256":        qmiVoiceControlExpectedSHA256,
		"remote_path":   qmiVoiceControlRemotePath,
		"persistent":    false,
		"operation":     "status",
	})
}
