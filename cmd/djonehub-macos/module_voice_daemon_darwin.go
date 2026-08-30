//go:build darwin && cgo

package main

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type voiceDaemonStatusRequest struct {
	Confirm          bool   `json:"confirm"`
	ConfirmOperation string `json:"confirm_operation"`
	ArtifactPath     string `json:"artifact_path"`
}

func defaultVoiceDaemonArtifactPath() string {
	return defaultPinnedQMIArtifactPath("djonehub-voice-daemon.armv7", validateVoiceDaemonArtifact)
}

func loadVoiceDaemonArtifact(path string) ([]byte, string, error) {
	if strings.TrimSpace(path) == "" {
		path = defaultVoiceDaemonArtifactPath()
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, "", fmt.Errorf("无法解析 QMI Voice daemon 路径: %w", err)
	}
	info, err := os.Lstat(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("无法读取 QMI Voice daemon: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, "", errors.New("QMI Voice daemon 必须是普通文件，不能是符号链接")
	}
	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("读取 QMI Voice daemon 失败: %w", err)
	}
	if err := validateVoiceDaemonArtifact(data); err != nil {
		return nil, "", err
	}
	return data, absPath, nil
}

func stopTemporaryVoiceDaemon(adb *adbClient) error {
	command := "if test -s '" + voiceDaemonRemotePIDPath + "'; then " +
		"read pid < '" + voiceDaemonRemotePIDPath + "' || true; " +
		"case \"$pid\" in ''|*[!0-9]*) true;; *) " +
		"owned() { test -d \"/proc/$pid\" && " +
		"test \"$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p')\" = '" + voiceDaemonRemotePath + "'; }; " +
		"if owned; then kill -TERM \"$pid\" 2>/dev/null || true; " +
		"attempt=0; while owned && test \"$attempt\" -lt 30; do sleep 0.1; attempt=$((attempt + 1)); done; " +
		"owned && exit 1 || true; fi;; esac; fi; " +
		"rm -f '" + voiceDaemonRemotePIDPath + "' '" + voiceDaemonRemoteLogPath + "' '" +
		voiceDaemonRemoteKeyPath + "' '" + voiceDaemonRemotePath + "'"
	return sentinelShell(adb, command, 10*time.Second)
}

func sentinelOwnedProcessRunning(adb *adbClient) bool {
	command := "for proc in /proc/[0-9]*; do test -r \"$proc/cmdline\" || continue; " +
		"argv0=$(tr '\\000' '\\n' < \"$proc/cmdline\" 2>/dev/null | sed -n '1p'); " +
		"test \"$argv0\" = '" + sentinelRemoteBinary + "' && exit 0; done; exit 1"
	_, status, err := adb.shellChecked(command, 8*time.Second)
	return err == nil && status == 0
}

func stopOwnedSentinelProcesses(adb *adbClient) error {
	command := "pids=''; for proc in /proc/[0-9]*; do test -r \"$proc/cmdline\" || continue; " +
		"argv0=$(tr '\\000' '\\n' < \"$proc/cmdline\" 2>/dev/null | sed -n '1p'); " +
		"if test \"$argv0\" = '" + sentinelRemoteBinary + "'; then pid=${proc#/proc/}; " +
		"case \"$pid\" in ''|*[!0-9]*) exit 1;; esac; kill -TERM \"$pid\" 2>/dev/null || true; pids=\"$pids $pid\"; fi; done; " +
		"attempt=0; while test \"$attempt\" -lt 30; do alive=0; for pid in $pids; do " +
		"test -d \"/proc/$pid\" && alive=1; done; test \"$alive\" = 0 && break; " +
		"sleep 0.1; attempt=$((attempt + 1)); done; " +
		"for pid in $pids; do test ! -d \"/proc/$pid\" || exit 1; done; rm -f '" + sentinelPIDFile + "'"
	return sentinelShell(adb, command, 10*time.Second)
}

func restartSentinelHealth(adb *adbClient) error {
	command := "test -x '" + sentinelRemoteBinary + "' || exit 0; " +
		"rm -f '" + sentinelPIDFile + "' '" + sentinelLogFile + "'; " +
		"nohup '" + sentinelRemoteBinary + "' --listen-address 192.168.225.1 --port 45750 " +
		"</dev/null >> '" + sentinelLogFile + "' 2>&1 & pid=$!; " +
		"printf '%s\\n' \"$pid\" > '" + sentinelPIDFile + "'; sleep 1; " +
		"test -d \"/proc/$pid\" && " +
		"test \"$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p')\" = '" + sentinelRemoteBinary + "'"
	return sentinelShell(adb, command, 10*time.Second)
}

func readVoiceControlFrame(connection net.Conn, expectedType byte) ([]byte, error) {
	header := make([]byte, voiceControlHeaderBytes)
	if _, err := io.ReadFull(connection, header); err != nil {
		return nil, err
	}
	_, payloadLength, _, err := validateVoiceControlHeader(header, expectedType)
	if err != nil || payloadLength > voiceControlMaxPayload {
		return nil, errors.New("控制响应帧头或长度无效")
	}
	extra := int(payloadLength)
	if expectedType == voiceControlFrameReply {
		extra += voiceControlTagBytes
	}
	frame := append([]byte(nil), header...)
	tail := make([]byte, extra)
	if _, err := io.ReadFull(connection, tail); err != nil {
		return nil, err
	}
	return append(frame, tail...), nil
}

func queryTemporaryVoiceDaemon(key []byte) (voiceDaemonReply, error) {
	var reply voiceDaemonReply
	connection, err := net.DialTimeout("tcp4", voiceDaemonAddress, 4*time.Second)
	if err != nil {
		return reply, err
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(8 * time.Second)); err != nil {
		return reply, err
	}
	hello, err := readVoiceControlFrame(connection, voiceControlFrameHello)
	if err != nil {
		return reply, err
	}
	nonce, err := decodeVoiceDaemonHello(hello)
	if err != nil {
		return reply, err
	}
	requestIDBytes := make([]byte, 8)
	if _, err := rand.Read(requestIDBytes); err != nil {
		return reply, err
	}
	requestID := binary.BigEndian.Uint64(requestIDBytes)
	if requestID == 0 {
		requestID = 1
	}
	request, err := encodeVoiceDaemonStatusRequest(key, nonce, requestID)
	if err != nil {
		return reply, err
	}
	for len(request) != 0 {
		written, writeErr := connection.Write(request)
		if writeErr != nil {
			return reply, writeErr
		}
		if written <= 0 {
			return reply, io.ErrUnexpectedEOF
		}
		request = request[written:]
	}
	frame, err := readVoiceControlFrame(connection, voiceControlFrameReply)
	if err != nil {
		return reply, err
	}
	return decodeVoiceDaemonReply(key, nonce, frame, requestID)
}

func (a *app) qmiVoiceDaemonStatusAPI(w http.ResponseWriter, r *http.Request) {
	var request voiceDaemonStatusRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm || request.ConfirmOperation != "status" {
		writeError(w, http.StatusBadRequest, "需要 confirm=true 且 confirm_operation=status")
		return
	}
	data, artifactPath, err := loadVoiceDaemonArtifact(request.ArtifactPath)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	key := make([]byte, voiceControlTagBytes)
	if _, err := rand.Read(key); err != nil {
		writeError(w, http.StatusInternalServerError, "生成临时 pairing key 失败: "+err.Error())
		return
	}
	defer func() {
		for index := range key {
			key[index] = 0
		}
	}()

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
	wasSentinelRunning := sentinelOwnedProcessRunning(adb)
	if wasSentinelRunning {
		if err := stopOwnedSentinelProcesses(adb); err != nil {
			writeError(w, http.StatusBadGateway, "停止已确认归属的 sentinel 失败: "+err.Error())
			return
		}
	}
	defer func() {
		if wasSentinelRunning {
			_ = restartSentinelHealth(adb)
		}
	}()
	if err := stopTemporaryVoiceDaemon(adb); err != nil {
		writeError(w, http.StatusBadGateway, "清理旧的临时 daemon 失败: "+err.Error())
		return
	}
	defer func() {
		_ = stopTemporaryVoiceDaemon(adb)
	}()
	if err := adb.pushContext(r.Context(), data, voiceDaemonRemotePath, 0o100700, 30*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "推送 QMI Voice daemon 失败: "+err.Error())
		return
	}
	if err := adb.pushContext(r.Context(), key, voiceDaemonRemoteKeyPath, 0o100600, 15*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "推送临时 pairing key 失败: "+err.Error())
		return
	}
	verifyAndStart := "chmod 700 '" + voiceDaemonRemotePath + "' && chmod 600 '" + voiceDaemonRemoteKeyPath + "' && " +
		"test \"$(sha256sum '" + voiceDaemonRemotePath + "' | awk '{print $1}')\" = '" + voiceDaemonExpectedSHA256 + "' && " +
		"test \"$(wc -c < '" + voiceDaemonRemoteKeyPath + "')\" = 32 && " +
		"rm -f '" + voiceDaemonRemotePIDPath + "' '" + voiceDaemonRemoteLogPath + "' && " +
		"{ LD_LIBRARY_PATH=/usr/lib nohup '" + voiceDaemonRemotePath + "' --once --key-file '" + voiceDaemonRemoteKeyPath + "' " +
		"</dev/null > '" + voiceDaemonRemoteLogPath + "' 2>&1 & pid=$!; " +
		"printf '%s\\n' \"$pid\" > '" + voiceDaemonRemotePIDPath + "'; }"
	if err := sentinelShell(adb, verifyAndStart, 15*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "启动临时 QMI Voice daemon 失败: "+err.Error())
		return
	}
	readyCommand := "attempt=0; while test \"$attempt\" -lt 20; do " +
		"if test -s '" + voiceDaemonRemotePIDPath + "'; then read pid < '" + voiceDaemonRemotePIDPath + "'; " +
		"if test -d \"/proc/$pid\" && grep -F 'authenticated control listening on 192.168.225.1:45750' '" + voiceDaemonRemoteLogPath + "' >/dev/null 2>&1; then exit 0; fi; " +
		"test -d \"/proc/$pid\" || break; fi; sleep 0.1; attempt=$((attempt + 1)); done; exit 1"
	if _, status, readyErr := adb.shellChecked(readyCommand, 8*time.Second); readyErr != nil || status != 0 {
		diagnostic := "printf 'pid='; test ! -f '" + voiceDaemonRemotePIDPath + "' || cat '" + voiceDaemonRemotePIDPath + "'; " +
			"echo; test ! -f '" + voiceDaemonRemoteLogPath + "' || tail -n 40 '" + voiceDaemonRemoteLogPath + "'; " +
			"awk '$2 ~ /:B2B6$/ && $4 == \"0A\" { print \"listener=\" $0 }' /proc/net/tcp"
		logOutput, _, _ := adb.shellChecked(diagnostic, 8*time.Second)
		writeError(w, http.StatusBadGateway, "QMI Voice daemon 未就绪: "+sentinelCleanShellOutput(logOutput))
		return
	}
	reply, err := queryTemporaryVoiceDaemon(key)
	if err != nil {
		writeError(w, http.StatusBadGateway, "认证 STATUS 闭环失败: "+err.Error())
		return
	}
	if reply.Status != 0 {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error": "daemon 返回错误状态", "reply": reply, "persistent": false,
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"authenticated": true,
		"reply":         reply,
		"artifact_path": artifactPath,
		"sha256":        voiceDaemonExpectedSHA256,
		"persistent":    false,
		"one_shot":      true,
	})
}
