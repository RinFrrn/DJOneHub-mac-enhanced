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
	"time"
)

const (
	smsGatewayAddress       = "192.168.225.1:45752"
	smsGatewayRemotePath    = "/tmp/djonehub-sms-daemon.armv7"
	smsGatewayRemoteKeyPath = "/tmp/djonehub-sms-control.key"
	smsGatewayRemotePIDPath = "/tmp/djonehub-sms-daemon.pid"
	smsGatewayRemoteLogPath = "/tmp/djonehub-sms-daemon.log"
)

func stopTemporarySMSGateway(adb *adbClient) error {
	command := "if test -s '" + smsGatewayRemotePIDPath + "'; then " +
		"read pid < '" + smsGatewayRemotePIDPath + "' || true; " +
		"case \"$pid\" in ''|*[!0-9]*) true;; *) " +
		"owned() { test -d \"/proc/$pid\" && " +
		"test \"$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p')\" = '" + smsGatewayRemotePath + "'; }; " +
		"if owned; then kill -TERM \"$pid\" 2>/dev/null || true; " +
		"attempt=0; while owned && test \"$attempt\" -lt 30; do sleep 0.1; attempt=$((attempt + 1)); done; " +
		"owned && exit 1 || true; fi;; esac; fi; " +
		"rm -f '" + smsGatewayRemotePIDPath + "' '" + smsGatewayRemoteLogPath + "' '" +
		smsGatewayRemoteKeyPath + "' '" + smsGatewayRemotePath + "'"
	return sentinelShell(adb, command, 10*time.Second)
}

func readSMSGatewayFrame(connection net.Conn, expectedType byte) ([]byte, error) {
	header := make([]byte, smsControlHeaderBytes)
	if _, err := io.ReadFull(connection, header); err != nil {
		return nil, err
	}
	if binary.BigEndian.Uint32(header[0:4]) != smsControlMagic ||
		header[4] != smsControlVersion || header[5] != expectedType ||
		header[10] != 0 || header[11] != 0 {
		return nil, errors.New("SMS gateway 响应帧头无效")
	}
	payloadLength := int(binary.BigEndian.Uint16(header[8:10]))
	maximum := smsControlMaxResponse
	if expectedType == smsControlFrameHello {
		maximum = smsControlNonceBytes
	}
	if payloadLength > maximum {
		return nil, errors.New("SMS gateway 响应 payload 超限")
	}
	extra := payloadLength
	if expectedType == smsControlFrameReply {
		extra += smsControlTagBytes
	}
	tail := make([]byte, extra)
	if _, err := io.ReadFull(connection, tail); err != nil {
		return nil, err
	}
	return append(header, tail...), nil
}

func queryTemporarySMSGateway(key []byte) (smsGatewayStatus, error) {
	var reply smsGatewayStatus
	connection, err := net.DialTimeout("tcp4", smsGatewayAddress, 4*time.Second)
	if err != nil {
		return reply, err
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(8 * time.Second)); err != nil {
		return reply, err
	}
	hello, err := readSMSGatewayFrame(connection, smsControlFrameHello)
	if err != nil {
		return reply, err
	}
	nonce, err := decodeSMSGatewayHello(hello)
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
	request, err := encodeSMSGatewayStatusRequest(key, nonce, requestID)
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
	frame, err := readSMSGatewayFrame(connection, smsControlFrameReply)
	if err != nil {
		return reply, err
	}
	return decodeSMSGatewayStatus(key, nonce, frame, requestID)
}

func queryTemporarySMSGatewayList(key []byte, storage byte) (smsGatewayList, error) {
	var reply smsGatewayList
	connection, err := net.DialTimeout("tcp4", smsGatewayAddress, 4*time.Second)
	if err != nil {
		return reply, err
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(12 * time.Second)); err != nil {
		return reply, err
	}
	hello, err := readSMSGatewayFrame(connection, smsControlFrameHello)
	if err != nil {
		return reply, err
	}
	nonce, err := decodeSMSGatewayHello(hello)
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
	request, err := encodeSMSGatewayListRequest(key, nonce, requestID, storage)
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
	frame, err := readSMSGatewayFrame(connection, smsControlFrameReply)
	if err != nil {
		return reply, err
	}
	return decodeSMSGatewayList(key, nonce, frame, requestID)
}

func (a *app) qmiSMSSessionStatusAPI(w http.ResponseWriter, r *http.Request) {
	var request voiceDaemonStatusRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm || request.ConfirmOperation != "sms-session-status" {
		writeError(w, http.StatusBadRequest, "需要 confirm=true 且 confirm_operation=sms-session-status")
		return
	}
	keyPath, err := stableDevelopmentControlKeyPath()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	key, err := readStableDevelopmentControlKey(keyPath)
	if err != nil {
		writeError(w, http.StatusBadGateway, "读取稳定开发 pairing key 失败: "+err.Error())
		return
	}
	defer func() {
		for index := range key {
			key[index] = 0
		}
	}()
	reply, err := queryTemporarySMSGateway(key)
	if err != nil {
		writeError(w, http.StatusBadGateway, "认证 SMS session STATUS 失败: "+err.Error())
		return
	}
	nvList, nvErr := queryTemporarySMSGatewayList(key, 1)
	simList, simErr := queryTemporarySMSGatewayList(key, 0)
	status := http.StatusOK
	if reply.Status != 0 || nvErr != nil || simErr != nil ||
		nvList.Status != 0 || simList.Status != 0 {
		status = http.StatusBadGateway
	}
	writeJSON(w, status, map[string]any{
		"authenticated": reply.Status == 0,
		"read_only":     true,
		"reply":         reply,
		"nv_list":       nvList,
		"sim_list":      simList,
		"nv_error":      errorString(nvErr),
		"sim_error":     errorString(simErr),
		"persistent":    true,
		"sha256":        voiceSMSExpectedSHA256,
	})
}

func errorString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func (a *app) qmiSMSGatewayStatusAPI(w http.ResponseWriter, r *http.Request) {
	var request voiceDaemonStatusRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm || request.ConfirmOperation != "sms-status" {
		writeError(w, http.StatusBadRequest, "需要 confirm=true 且 confirm_operation=sms-status")
		return
	}
	data, artifactPath, err := loadVoiceSMSArtifact(request.ArtifactPath)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	key := make([]byte, smsControlTagBytes)
	if _, err := rand.Read(key); err != nil {
		writeError(w, http.StatusInternalServerError, "生成临时 SMS pairing key 失败: "+err.Error())
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
	if err := sentinelRequireRoot(adb); err != nil {
		adb.Close()
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := stopTemporarySMSGateway(adb); err != nil {
		adb.Close()
		writeError(w, http.StatusBadGateway, "清理旧临时短信网关失败: "+err.Error())
		return
	}
	if err := adb.pushContext(r.Context(), data, smsGatewayRemotePath, 0o100700, 30*time.Second); err != nil {
		adb.Close()
		writeError(w, http.StatusBadGateway, "推送短信认证网关失败: "+err.Error())
		return
	}
	if err := adb.pushContext(r.Context(), key, smsGatewayRemoteKeyPath, 0o100600, 15*time.Second); err != nil {
		_ = stopTemporarySMSGateway(adb)
		adb.Close()
		writeError(w, http.StatusBadGateway, "推送临时 SMS pairing key 失败: "+err.Error())
		return
	}
	start := "chmod 700 '" + smsGatewayRemotePath + "' && chmod 600 '" + smsGatewayRemoteKeyPath + "' && " +
		"test \"$(sha256sum '" + smsGatewayRemotePath + "' | awk '{print $1}')\" = '" + voiceSMSExpectedSHA256 + "' && " +
		"test \"$(wc -c < '" + smsGatewayRemoteKeyPath + "')\" = 32 && " +
		"rm -f '" + smsGatewayRemotePIDPath + "' '" + smsGatewayRemoteLogPath + "' && { " +
		"LD_LIBRARY_PATH=/usr/lib nohup '" + smsGatewayRemotePath + "' --read-only --key-file '" + smsGatewayRemoteKeyPath + "' " +
		"</dev/null >'" + smsGatewayRemoteLogPath + "' 2>&1 & pid=$!; printf '%s\\n' \"$pid\" >'" + smsGatewayRemotePIDPath + "'; " +
		"ready=0; attempt=0; while test \"$attempt\" -lt 30; do " +
		"if test -d \"/proc/$pid\" && grep -F 'authenticated SMS control listening on 192.168.225.1:45752' '" + smsGatewayRemoteLogPath + "' >/dev/null 2>&1; then ready=1; break; fi; " +
		"test -d \"/proc/$pid\" || break; sleep 0.1; attempt=$((attempt + 1)); done; test \"$ready\" = 1; }"
	if err := sentinelShell(adb, start, 12*time.Second); err != nil {
		diagnostic, _, _ := adb.shellChecked("test ! -f '"+smsGatewayRemoteLogPath+"' || tail -n 40 '"+smsGatewayRemoteLogPath+"'", 8*time.Second)
		_ = stopTemporarySMSGateway(adb)
		adb.Close()
		writeError(w, http.StatusBadGateway, "短信认证网关未就绪: "+sentinelCleanShellOutput(diagnostic))
		return
	}
	adb.Close()
	var reply smsGatewayStatus
	var queryErr error
	recoveryAttempts := 0
	preflightDeadline := time.Now().Add(voiceTestECMPreflightTimeout)
	for attempt := 0; attempt < 40 && time.Now().Before(preflightDeadline); attempt++ {
		reply, queryErr = queryTemporarySMSGateway(key)
		if queryErr == nil {
			break
		}
		// Most macOS USB stacks restore ECM by themselves after the ADB claim
		// closes.  Only perform the additional ADB open/close recovery if the
		// direct route has remained unusable for several probes; doing it
		// eagerly can interrupt an ECM link that was already healthy.
		if recoveryAttempts < 3 &&
			(attempt == 5 || attempt == 15 || attempt == 25) {
			recoveryAttempts++
			recoveryADB, recoveryErr := openDJIUSBADB()
			if recoveryErr == nil {
				_, _, _ = recoveryADB.shellChecked("true", 4*time.Second)
				recoveryADB.Close()
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	var nvList smsGatewayList
	var simList smsGatewayList
	var nvListErr error
	var simListErr error
	if queryErr == nil && reply.Status == 0 {
		nvList, nvListErr = queryTemporarySMSGatewayList(key, 1)
		simList, simListErr = queryTemporarySMSGatewayList(key, 0)
	}
	adb, reopenErr := openDJIUSBADB()
	gatewayLog := ""
	if reopenErr == nil {
		logOutput, _, _ := adb.shellChecked("test ! -f '"+smsGatewayRemoteLogPath+"' || tail -n 40 '"+smsGatewayRemoteLogPath+"'", 8*time.Second)
		gatewayLog = sentinelCleanShellOutput(logOutput)
		_ = stopTemporarySMSGateway(adb)
		adb.Close()
	}
	if queryErr != nil {
		writeError(w, http.StatusBadGateway, "认证 SMS STATUS 闭环失败: "+queryErr.Error())
		return
	}
	if reply.Status != 0 {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error": "SMS gateway 返回错误状态", "reply": reply,
			"module_log": gatewayLog, "persistent": false,
		})
		return
	}
	if nvListErr != nil || simListErr != nil || nvList.Status != 0 || simList.Status != 0 {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error":      fmt.Sprintf("SMS LIST 验证失败: nv=%v sim=%v", nvListErr, simListErr),
			"nv_list":    nvList,
			"sim_list":   simList,
			"module_log": gatewayLog,
			"persistent": false,
		})
		return
	}
	response := map[string]any{
		"authenticated": true,
		"read_only":     true,
		"reply":         reply,
		"artifact_path": artifactPath,
		"sha256":        voiceSMSExpectedSHA256,
		"persistent":    false,
		"one_shot":      true,
		"module_log":    gatewayLog,
		"nv_list":       nvList,
		"sim_list":      simList,
	}
	if reopenErr != nil {
		response["cleanup_warning"] = fmt.Sprintf("无法重新打开模块 ADB 清理临时文件: %v", reopenErr)
	}
	writeJSON(w, http.StatusOK, response)
}
