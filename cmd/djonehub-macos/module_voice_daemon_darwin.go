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

type voiceTestArmRequest struct {
	Confirm          bool   `json:"confirm"`
	ConfirmOperation string `json:"confirm_operation"`
	ArtifactPath     string `json:"artifact_path"`
}

func voiceTestInstallLinkCommand() string {
	return "root_rw=0; " +
		"restore_ro() { if test \"$root_rw\" = 1; then sync; mount -o remount,ro /; fi; }; " +
		"trap restore_ro EXIT HUP INT TERM; " +
		"mount -o remount,rw / && root_rw=1 && " +
		"test ! -e '" + voiceTestInitLink + "' && test ! -L '" + voiceTestInitLink + "' && " +
		"ln -s '" + voiceTestRemoteScript + "' '" + voiceTestInitLink + "' && " +
		"sync && mount -o remount,ro / && root_rw=0 && " +
		"test \"$(readlink '" + voiceTestInitLink + "')\" = '" + voiceTestRemoteScript + "' && " +
		"awk '$2 == \"/\" && $4 ~ /(^|,)ro(,|$)/ { found=1 } END { exit found ? 0 : 1 }' /proc/mounts"
}

func voiceTestRemoveLinkCommand() string {
	return "root_rw=0; " +
		"restore_ro() { if test \"$root_rw\" = 1; then sync; mount -o remount,ro /; fi; }; " +
		"trap restore_ro EXIT HUP INT TERM; " +
		"mount -o remount,rw / && root_rw=1 && " +
		"test \"$(readlink '" + voiceTestInitLink + "')\" = '" + voiceTestRemoteScript + "' && " +
		"rm -f '" + voiceTestInitLink + "' && sync && " +
		"mount -o remount,ro / && root_rw=0 && test ! -e '" + voiceTestInitLink + "' && " +
		"awk '$2 == \"/\" && $4 ~ /(^|,)ro(,|$)/ { found=1 } END { exit found ? 0 : 1 }' /proc/mounts"
}

func voiceTestCheckLink(adb *adbClient) (string, error) {
	out, status, err := adb.shellChecked(
		"if test -L '"+voiceTestInitLink+"'; then readlink '"+voiceTestInitLink+"'; "+
			"elif test -e '"+voiceTestInitLink+"'; then echo __CONFLICT__; else echo __ABSENT__; fi",
		8*time.Second,
	)
	if err != nil || status != 0 {
		return "", fmt.Errorf("检查测试启动链接失败: %v %s", err, sentinelCleanShellOutput(out))
	}
	return sentinelCleanShellOutput(out), nil
}

func stopVoiceTestProcess(adb *adbClient) error {
	command := "if test -s '" + voiceTestPIDFile + "'; then " +
		"read pid < '" + voiceTestPIDFile + "' || true; " +
		"case \"$pid\" in ''|*[!0-9]*) true;; *) " +
		"owned() { test -d \"/proc/$pid\" && " +
		"test \"$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p')\" = '" + voiceTestRemoteBinary + "'; }; " +
		"if owned; then kill -TERM \"$pid\" 2>/dev/null || true; " +
		"attempt=0; while owned && test \"$attempt\" -lt 30; do sleep 0.1; attempt=$((attempt + 1)); done; " +
		"owned && exit 1 || true; fi;; esac; fi; rm -f '" + voiceTestPIDFile + "'"
	return sentinelShell(adb, command, 8*time.Second)
}

func startVoiceTestForValidation(adb *adbClient) error {
	command := "rm -f '" + voiceTestPIDFile + "' /tmp/djonehub-voice-test-validate.log; " +
		"LD_LIBRARY_PATH=/usr/lib nohup '" + voiceTestRemoteBinary + "' --key-file '" + voiceTestRemoteKey + "' " +
		"</dev/null >/tmp/djonehub-voice-test-validate.log 2>&1 & pid=$!; " +
		"printf '%s\\n' \"$pid\" > '" + voiceTestPIDFile + "'; " +
		"ready=0; attempt=0; while test \"$attempt\" -lt 30; do " +
		"if test -d \"/proc/$pid\" && grep -F 'authenticated control listening on 192.168.225.1:45750' /tmp/djonehub-voice-test-validate.log >/dev/null 2>&1; then ready=1; break; fi; " +
		"test -d \"/proc/$pid\" || break; sleep 0.1; attempt=$((attempt + 1)); done; test \"$ready\" = 1"
	return sentinelShell(adb, command, 10*time.Second)
}

func installVoiceTestLink(adb *adbClient) error {
	state, err := voiceTestCheckLink(adb)
	if err != nil {
		return err
	}
	if state == voiceTestRemoteScript {
		return nil
	}
	if state != "__ABSENT__" {
		return fmt.Errorf("拒绝覆盖已有启动项 %s（当前：%s）", voiceTestInitLink, state)
	}
	return sentinelShell(adb, voiceTestInstallLinkCommand(), 15*time.Second)
}

func removeVoiceTestLink(adb *adbClient) error {
	state, err := voiceTestCheckLink(adb)
	if err != nil || state == "__ABSENT__" {
		return err
	}
	if state != voiceTestRemoteScript {
		return fmt.Errorf("拒绝删除非 DJOneHub 启动项 %s（当前：%s）", voiceTestInitLink, state)
	}
	return sentinelShell(adb, voiceTestRemoveLinkCommand(), 15*time.Second)
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
	command := "found=0; for proc in /proc/[0-9]*; do test -r \"$proc/cmdline\" || continue; " +
		"argv0=$(tr '\\000' '\\n' < \"$proc/cmdline\" 2>/dev/null | sed -n '1p'); " +
		"if test \"$argv0\" = '" + sentinelRemoteBinary + "'; then found=1; break; fi; done; test \"$found\" = 1"
	_, status, err := adb.shellChecked(command, 8*time.Second)
	return err == nil && status == 0
}

func stopOwnedSentinelProcesses(adb *adbClient) error {
	command := "pids=''; for proc in /proc/[0-9]*; do test -r \"$proc/cmdline\" || continue; " +
		"argv0=$(tr '\\000' '\\n' < \"$proc/cmdline\" 2>/dev/null | sed -n '1p'); " +
		"if test \"$argv0\" = '" + sentinelRemoteBinary + "'; then pid=${proc#/proc/}; " +
		"case \"$pid\" in ''|*[!0-9]*) continue;; esac; kill -TERM \"$pid\" 2>/dev/null || true; pids=\"$pids $pid\"; fi; done; " +
		"attempt=0; while test \"$attempt\" -lt 30; do alive=0; for pid in $pids; do " +
		"test -d \"/proc/$pid\" && alive=1; done; test \"$alive\" = 0 && break; " +
		"sleep 0.1; attempt=$((attempt + 1)); done; " +
		"failed=0; for pid in $pids; do test ! -d \"/proc/$pid\" || failed=1; done; " +
		"test \"$failed\" = 0 && rm -f '" + sentinelPIDFile + "'"
	return sentinelShell(adb, command, 10*time.Second)
}

func restartSentinelHealth(adb *adbClient) error {
	command := "if test -x '" + sentinelRemoteBinary + "'; then " +
		"rm -f '" + sentinelPIDFile + "' '" + sentinelLogFile + "'; " +
		"nohup '" + sentinelRemoteBinary + "' --listen-address 192.168.225.1 --port 45750 " +
		"</dev/null >> '" + sentinelLogFile + "' 2>&1 & pid=$!; " +
		"printf '%s\\n' \"$pid\" > '" + sentinelPIDFile + "'; sleep 1; " +
		"test -d \"/proc/$pid\" && " +
		"test \"$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p')\" = '" + sentinelRemoteBinary + "'; fi"
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
		"printf '%s\\n' \"$pid\" > '" + voiceDaemonRemotePIDPath + "'; sleep 1; }"
	if err := sentinelShell(adb, verifyAndStart, 15*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "启动临时 QMI Voice daemon 失败: "+err.Error())
		return
	}
	readyCommand := "ready=0; attempt=0; while test \"$attempt\" -lt 20; do " +
		"if test -s '" + voiceDaemonRemotePIDPath + "'; then read pid < '" + voiceDaemonRemotePIDPath + "'; " +
		"if test -d \"/proc/$pid\" && grep -F 'authenticated control listening on 192.168.225.1:45750' '" + voiceDaemonRemoteLogPath + "' >/dev/null 2>&1; then ready=1; break; fi; " +
		"test -d \"/proc/$pid\" || break; fi; sleep 0.1; attempt=$((attempt + 1)); done; test \"$ready\" = 1"
	if _, status, readyErr := adb.shellChecked(readyCommand, 8*time.Second); readyErr != nil || status != 0 {
		diagnostic := "printf 'pid='; test ! -f '" + voiceDaemonRemotePIDPath + "' || cat '" + voiceDaemonRemotePIDPath + "'; " +
			"echo; if test -s '" + voiceDaemonRemotePIDPath + "'; then read pid < '" + voiceDaemonRemotePIDPath + "'; " +
			"printf 'cmdline='; tr '\\000' ' ' < \"/proc/$pid/cmdline\" 2>/dev/null || true; echo; " +
			"printf 'wchan='; cat \"/proc/$pid/wchan\" 2>/dev/null || true; echo; " +
			"echo 'status_begin'; sed -n '1,40p' \"/proc/$pid/status\" 2>/dev/null || true; echo 'status_end'; fi; " +
			"ls -l '" + voiceDaemonRemoteLogPath + "' 2>/dev/null || true; " +
			"echo 'daemon_log_begin'; test ! -f '" + voiceDaemonRemoteLogPath + "' || tail -n 40 '" + voiceDaemonRemoteLogPath + "'; echo 'daemon_log_end'; " +
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

func (a *app) voiceTestStatusAPI(w http.ResponseWriter, _ *http.Request) {
	a.moduleVoiceOpMu.Lock()
	defer a.moduleVoiceOpMu.Unlock()
	adb, err := openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer adb.Close()
	out, status, err := adb.shellChecked(
		"printf 'binary=%s\\n' \"$(test -x '"+voiceTestRemoteBinary+"' && echo yes || echo no)\"; "+
			"printf 'key=%s\\n' \"$(test -f '"+voiceTestRemoteKey+"' && echo present || echo absent)\"; "+
			"printf 'marker=%s\\n' \"$(test -f '"+voiceTestRemoteMarker+"' && echo armed || echo absent)\"; "+
			"printf 'link=%s\\n' \"$(test -L '"+voiceTestInitLink+"' && readlink '"+voiceTestInitLink+"' || echo absent)\"; "+
			"printf 'state=%s\\n' \"$(test -f '"+voiceTestRemoteState+"' && cat '"+voiceTestRemoteState+"' || echo absent)\"; "+
			"echo 'log_begin'; test ! -f '"+voiceTestRemoteLog+"' || tail -n 60 '"+voiceTestRemoteLog+"'; echo 'log_end'",
		8*time.Second,
	)
	if err != nil || status != 0 {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("读取 iOS STATUS 测试状态失败: %v %s", err, sentinelCleanShellOutput(out)))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"detail": sentinelCleanShellOutput(out)})
}

func (a *app) voiceTestArmOnceAPI(w http.ResponseWriter, r *http.Request) {
	var request voiceTestArmRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm || request.ConfirmOperation != "arm-ios-status-once" {
		writeError(w, http.StatusBadRequest, "需要 confirm=true 且 confirm_operation=arm-ios-status-once")
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
	bundle, identifier, err := encodeDevelopmentPairingBundle(key, time.Now())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "生成测试配对包失败: "+err.Error())
		return
	}

	a.moduleVoiceOpMu.Lock()
	defer a.moduleVoiceOpMu.Unlock()
	adb, err := openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer adb.Close()
	if err := sentinelRequireRoot(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if _, status, err := adb.shellChecked("test ! -f '"+sentinelRemoteMarker+"'", 8*time.Second); err != nil || status != 0 {
		writeError(w, http.StatusConflict, "sentinel 仍处于 armed 状态，请先卸载或消费 sentinel")
		return
	}
	wasSentinelRunning := sentinelOwnedProcessRunning(adb)
	if wasSentinelRunning {
		if err := stopOwnedSentinelProcesses(adb); err != nil {
			writeError(w, http.StatusBadGateway, "停止 sentinel 失败: "+err.Error())
			return
		}
		defer func() { _ = restartSentinelHealth(adb) }()
	}
	if err := stopTemporaryVoiceDaemon(adb); err != nil {
		writeError(w, http.StatusBadGateway, "清理临时 daemon 失败: "+err.Error())
		return
	}
	if err := stopVoiceTestProcess(adb); err != nil {
		writeError(w, http.StatusBadGateway, "停止旧测试 daemon 失败: "+err.Error())
		return
	}
	armed := false
	defer func() {
		if !armed {
			_ = sentinelShell(adb, "rm -f '"+voiceTestRemoteKey+"' '"+voiceTestRemoteMarker+"'", 8*time.Second)
		}
	}()
	if err := sentinelShell(adb, "test -d /usrdata && mkdir -p '"+voiceTestRemoteDir+"' && chmod 700 '"+voiceTestRemoteDir+"'", 8*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "准备测试目录失败: "+err.Error())
		return
	}
	if err := adb.pushContext(r.Context(), data, voiceTestRemoteBinary, 0o100700, 30*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "推送认证 daemon 失败: "+err.Error())
		return
	}
	if err := adb.pushContext(r.Context(), key, voiceTestRemoteKey, 0o100600, 15*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "推送测试 pairing key 失败: "+err.Error())
		return
	}
	if err := adb.pushContext(r.Context(), []byte(voiceTestStartOnceScript), voiceTestRemoteScript, 0o100700, 15*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "推送测试启动脚本失败: "+err.Error())
		return
	}
	verify := "chmod 700 '" + voiceTestRemoteBinary + "' '" + voiceTestRemoteScript + "' && chmod 600 '" + voiceTestRemoteKey + "' && " +
		"test \"$(sha256sum '" + voiceTestRemoteBinary + "' | awk '{print $1}')\" = '" + voiceDaemonExpectedSHA256 + "' && " +
		"test \"$(wc -c < '" + voiceTestRemoteKey + "')\" = 32"
	if err := sentinelShell(adb, verify, 12*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "模块端测试文件校验失败: "+err.Error())
		return
	}
	if err := startVoiceTestForValidation(adb); err != nil {
		writeError(w, http.StatusBadGateway, "认证 daemon 临时启动失败: "+err.Error())
		return
	}
	reply, queryErr := queryTemporaryVoiceDaemon(key)
	stopErr := stopVoiceTestProcess(adb)
	if queryErr != nil || reply.Status != 0 || stopErr != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("认证 STATUS 预检失败: query=%v status=%d stop=%v", queryErr, reply.Status, stopErr))
		return
	}
	if err := installVoiceTestLink(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := sentinelShell(adb,
		"rm -f '"+voiceTestRemoteState+"' '"+voiceTestRemoteLog+"' && : > '"+voiceTestRemoteMarker+"' && chmod 600 '"+voiceTestRemoteMarker+"' && sync",
		8*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "设置一次性测试标记失败: "+err.Error())
		return
	}
	armed = true
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", "attachment; filename=DJOneHub-STATUS-pairing-"+identifier[:8]+".json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-DJOneHub-Artifact-Path", artifactPath)
	w.Header().Set("X-DJOneHub-Module-Identifier", identifier)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(bundle)
}

func (a *app) voiceTestUninstallAPI(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Confirm bool `json:"confirm"`
	}
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm {
		writeError(w, http.StatusBadRequest, "需要明确确认卸载 iOS STATUS 测试")
		return
	}
	a.moduleVoiceOpMu.Lock()
	defer a.moduleVoiceOpMu.Unlock()
	adb, err := openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer adb.Close()
	if err := sentinelRequireRoot(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := removeVoiceTestLink(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := stopVoiceTestProcess(adb); err != nil {
		writeError(w, http.StatusBadGateway, "停止测试 daemon 失败: "+err.Error())
		return
	}
	cleanup := "rm -f '" + voiceTestRemoteMarker + "' '" + voiceTestRemoteState + "' '" + voiceTestRemoteLog + "' '" +
		voiceTestRemoteScript + "' '" + voiceTestRemoteBinary + "' '" + voiceTestRemoteKey + "' '" + voiceTestPIDFile + "'; " +
		"rmdir '" + voiceTestRemoteDir + "' 2>/dev/null || true; sync"
	if err := sentinelShell(adb, cleanup, 10*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "清理 iOS STATUS 测试失败: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"uninstalled": true})
}
