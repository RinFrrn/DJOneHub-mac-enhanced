//go:build darwin && cgo

package main

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type qmiVoiceProbeRequest struct {
	Confirm      bool   `json:"confirm"`
	ArtifactPath string `json:"artifact_path"`
}

type qmiVoiceControlRequest struct {
	Confirm          bool   `json:"confirm"`
	ConfirmOperation string `json:"confirm_operation"`
	ArtifactPath     string `json:"artifact_path"`
	Number           string `json:"number"`
	CallID           int    `json:"call_id"`
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

func (a *app) runQMIVoiceControlCandidate(w http.ResponseWriter, r *http.Request, data []byte, artifactPath, operation, argument string) {
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

	// Operation is selected only by a fixed route handler. Argument has already
	// passed a strict digits/*/#/+ or decimal call-ID validator, so neither can
	// become an arbitrary shell or QMI message.
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

	command := operation
	if argument != "" {
		command += " '" + argument + "'"
	}
	verifyAndRun := "chmod 700 '" + qmiVoiceControlRemotePath + "' && " +
		"test \"$(sha256sum '" + qmiVoiceControlRemotePath + "' | awk '{print $1}')\" = '" + qmiVoiceControlExpectedSHA256 + "' && " +
		"LD_LIBRARY_PATH=/usr/lib '" + qmiVoiceControlRemotePath + "' " + command + " 2>&1"
	output, status, runErr := adb.shellChecked(verifyAndRun, 35*time.Second)
	cleanOutput := sentinelCleanShellOutput(output)
	if runErr != nil || status != 0 {
		runErrorText := fmt.Sprintf("exit status %d", status)
		if runErr != nil {
			runErrorText = runErr.Error()
		}
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error":         "运行 QMI Voice 控制候选 " + operation + " 失败: " + runErrorText,
			"output":        cleanOutput,
			"exit_status":   status,
			"artifact_path": artifactPath,
			"sha256":        qmiVoiceControlExpectedSHA256,
			"persistent":    false,
			"operation":     operation,
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"compatible":    true,
		"exit_status":   status,
		"output":        cleanOutput,
		"artifact_path": artifactPath,
		"sha256":        qmiVoiceControlExpectedSHA256,
		"remote_path":   qmiVoiceControlRemotePath,
		"persistent":    false,
		"operation":     operation,
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
	a.runQMIVoiceControlCandidate(w, r, data, artifactPath, "status", "")
}

func (a *app) qmiVoiceControlDialAPI(w http.ResponseWriter, r *http.Request) {
	var request qmiVoiceControlRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm || request.ConfirmOperation != "dial" {
		writeError(w, http.StatusBadRequest, "需要 confirm=true 且 confirm_operation=dial")
		return
	}
	if !validQMIVoiceDialNumber(request.Number) {
		writeError(w, http.StatusBadRequest, "拨号号码无效，只允许数字、开头的 +、* 和 #")
		return
	}
	data, artifactPath, err := loadQMIVoiceControlArtifact(request.ArtifactPath)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	a.runQMIVoiceControlCandidate(w, r, data, artifactPath, "dial", request.Number)
}

func (a *app) qmiVoiceControlAnswerAPI(w http.ResponseWriter, r *http.Request) {
	a.qmiVoiceControlCallIDAPI(w, r, "answer")
}

func (a *app) qmiVoiceControlEndAPI(w http.ResponseWriter, r *http.Request) {
	a.qmiVoiceControlCallIDAPI(w, r, "end")
}

func (a *app) qmiVoiceControlCallIDAPI(w http.ResponseWriter, r *http.Request, operation string) {
	var request qmiVoiceControlRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm || request.ConfirmOperation != operation {
		writeError(w, http.StatusBadRequest, "需要 confirm=true 且 confirm_operation="+operation)
		return
	}
	if !validQMIVoiceCallID(request.CallID) {
		writeError(w, http.StatusBadRequest, "call_id 必须在 1..255")
		return
	}
	data, artifactPath, err := loadQMIVoiceControlArtifact(request.ArtifactPath)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	a.runQMIVoiceControlCandidate(w, r, data, artifactPath, operation, strconv.Itoa(request.CallID))
}
