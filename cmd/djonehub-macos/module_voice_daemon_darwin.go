//go:build darwin && cgo

package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
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
	Confirm                bool   `json:"confirm"`
	ConfirmOperation       string `json:"confirm_operation"`
	ArtifactPath           string `json:"artifact_path"`
	UplinkArtifactPath     string `json:"uplink_artifact_path"`
	IncallCardArtifactPath string `json:"incall_card_artifact_path"`
	PairingBundlePath      string `json:"pairing_bundle_path"`
	RotatePairing          bool   `json:"rotate_pairing"`
}

type voiceTestArmMode struct {
	confirmOperation string
	purpose          string
	markerPath       string
	filePrefix       string
}

const voiceTestECMPreflightTimeout = 25 * time.Second

var (
	voiceStatusOnceMode = voiceTestArmMode{
		confirmOperation: "arm-ios-status-once",
		purpose:          voiceTestStatusPurpose,
		markerPath:       voiceTestRemoteOnceMarker,
		filePrefix:       "DJOneHub-STATUS-pairing-",
	}
	voiceControlSessionMode = voiceTestArmMode{
		confirmOperation: "arm-ios-control-session",
		purpose:          voiceTestSessionPurpose,
		markerPath:       voiceTestRemoteSessionMarker,
		filePrefix:       "DJOneHub-CONTROL-pairing-",
	}
)

func stableDevelopmentControlKeyPath() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("无法确定开发配对目录: %w", err)
	}
	return filepath.Join(configDir, "DJOneHub", "pairing", "development-control.key"), nil
}

func readStableDevelopmentControlKey(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("稳定开发配对密钥必须是普通文件")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("稳定开发配对密钥权限必须为 0600")
	}
	key, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(key) != voiceControlTagBytes {
		return nil, fmt.Errorf("稳定开发配对密钥长度无效: %d", len(key))
	}
	return key, nil
}

func developmentControlKeyFromBundle(path string, now time.Time) ([]byte, error) {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	info, err := os.Lstat(absPath)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("种子配对包必须是普通文件")
	}
	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, err
	}
	var bundle developmentPairingBundle
	if err := json.Unmarshal(data, &bundle); err != nil {
		return nil, errors.New("种子配对包 JSON 无效")
	}
	if bundle.Version != 1 || bundle.Purpose != voiceTestSessionPurpose ||
		bundle.Host != "192.168.225.1" || bundle.Port != 45750 {
		return nil, errors.New("种子配对包用途或端点无效")
	}
	expiresAt, err := time.Parse(time.RFC3339, bundle.ExpiresAt)
	if err != nil || !expiresAt.After(now) {
		return nil, errors.New("种子配对包已过期或时间无效")
	}
	key, err := base64.StdEncoding.DecodeString(bundle.PairingKeyBase64)
	if err != nil || len(key) != voiceControlTagBytes {
		return nil, errors.New("种子配对包密钥无效")
	}
	identifier, err := developmentPairingModuleIdentifier(key)
	if err != nil || identifier != bundle.ModuleIdentifier {
		return nil, errors.New("种子配对包标识与密钥不匹配")
	}
	return key, nil
}

func persistStableDevelopmentControlKey(path string, key []byte) error {
	if len(key) != voiceControlTagBytes {
		return errors.New("稳定开发配对密钥长度无效")
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(dir, ".development-control-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer func() { _ = os.Remove(temporaryPath) }()
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(key); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

func stableDevelopmentControlKey(seedBundlePath string, rotate bool, now time.Time) ([]byte, string, error) {
	path, err := stableDevelopmentControlKeyPath()
	if err != nil {
		return nil, "", err
	}
	if rotate {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, "", fmt.Errorf("轮换旧开发配对密钥失败: %w", err)
		}
	}
	key, err := readStableDevelopmentControlKey(path)
	if err == nil {
		return key, path, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, "", err
	}
	if strings.TrimSpace(seedBundlePath) != "" {
		key, err = developmentControlKeyFromBundle(seedBundlePath, now)
	} else {
		key = make([]byte, voiceControlTagBytes)
		_, err = rand.Read(key)
	}
	if err != nil {
		return nil, "", err
	}
	if err := persistStableDevelopmentControlKey(path, key); err != nil {
		return nil, "", err
	}
	return key, path, nil
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

func stopOwnedVoiceTestProcess(adb *adbClient, pidFile, binary string) error {
	command := "if test -s '" + pidFile + "'; then " +
		"read pid < '" + pidFile + "' || true; " +
		"case \"$pid\" in ''|*[!0-9]*) true;; *) " +
		"owned() { test -d \"/proc/$pid\" && " +
		"test \"$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p')\" = '" + binary + "'; }; " +
		"if owned; then kill -TERM \"$pid\" 2>/dev/null || true; " +
		"attempt=0; while owned && test \"$attempt\" -lt 30; do sleep 0.1; attempt=$((attempt + 1)); done; " +
		"owned && exit 1 || true; fi;; esac; fi; rm -f '" + pidFile + "'"
	return sentinelShell(adb, command, 8*time.Second)
}

func stopVoiceTestProcess(adb *adbClient) error {
	return stopOwnedVoiceTestProcess(adb, voiceTestPIDFile, voiceTestRemoteBinary)
}

func stopVoiceTestUplinkProcess(adb *adbClient) error {
	return stopOwnedVoiceTestProcess(adb, voiceTestUplinkPIDFile, voiceTestRemoteUplink)
}

func startVoiceTestForValidation(adb *adbClient) error {
	command := "rm -f '" + voiceTestPIDFile + "' /tmp/djonehub-voice-test-validate.log; " +
		"LD_LIBRARY_PATH=/usr/lib nohup '" + voiceTestRemoteBinary + "' --once --status-only --key-file '" + voiceTestRemoteKey + "' " +
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

func defaultVoiceUplinkArtifactPath() string {
	return defaultPinnedQMIArtifactPath("mavo-pcm-bridge.armv7", validateVoiceUplinkArtifact)
}

func validateVoiceUplinkArtifact(data []byte) error {
	if len(data) == 0 || len(data) > qmiVoiceProbeMaximumSize {
		return fmt.Errorf("PCM 上行 bridge 文件大小无效：%d bytes", len(data))
	}
	if err := validateQMIVoiceProbeELF(data); err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	actual := hex.EncodeToString(sum[:])
	if actual != voiceUplinkExpectedSHA256 {
		return fmt.Errorf("PCM 上行 bridge SHA-256 不匹配：需要 %s，实际 %s", voiceUplinkExpectedSHA256, actual)
	}
	return nil
}

func loadVoiceUplinkArtifact(path string) ([]byte, string, error) {
	if strings.TrimSpace(path) == "" {
		path = defaultVoiceUplinkArtifactPath()
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, "", fmt.Errorf("无法解析 PCM 上行 bridge 路径: %w", err)
	}
	info, err := os.Lstat(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("无法读取 PCM 上行 bridge: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, "", errors.New("PCM 上行 bridge 必须是普通文件，不能是符号链接")
	}
	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("读取 PCM 上行 bridge 失败: %w", err)
	}
	if err := validateVoiceUplinkArtifact(data); err != nil {
		return nil, "", err
	}
	return data, absPath, nil
}

func defaultVoiceIncallCardArtifactPath() string {
	return defaultPinnedQMIArtifactPath("qdc507_incall_card.new.ko", validateVoiceIncallCardArtifact)
}

func loadVoiceIncallCardArtifact(path string) ([]byte, string, error) {
	if strings.TrimSpace(path) == "" {
		path = defaultVoiceIncallCardArtifactPath()
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, "", fmt.Errorf("无法解析 QDC507 in-call card 路径: %w", err)
	}
	info, err := os.Lstat(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("无法读取 QDC507 in-call card: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, "", errors.New("QDC507 in-call card 必须是普通文件，不能是符号链接")
	}
	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("读取 QDC507 in-call card 失败: %w", err)
	}
	if err := validateVoiceIncallCardArtifact(data); err != nil {
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

func isVoiceDaemonDialUnavailable(err error) bool {
	var operationError *net.OpError
	return errors.As(err, &operationError) && operationError.Op == "dial"
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
			"printf 'uplink_binary=%s\\n' \"$(test -x '"+voiceTestRemoteUplink+"' && echo yes || echo no)\"; "+
			"printf 'aprv3_binary=%s\\n' \"$(test -f '"+voiceTestRemoteAPRv3+"' && echo yes || echo no)\"; "+
			"printf 'voice_binary=%s\\n' \"$(test -f '"+voiceTestRemoteVoice+"' && echo yes || echo no)\"; "+
			"printf 'incall_card_binary=%s\\n' \"$(test -f '"+voiceTestRemoteIncallCard+"' && echo yes || echo no)\"; "+
			"printf 'incall_prepare=%s\\n' \"$(test -x '"+voiceTestRemotePrepareCard+"' && echo yes || echo no)\"; "+
			"printf 'uplink_process=%s\\n' \"$(test -s '"+voiceTestUplinkPIDFile+"' && read pid < '"+voiceTestUplinkPIDFile+"' && test -d \"/proc/$pid\" && echo running || echo stopped)\"; "+
			"printf 'key=%s\\n' \"$(test -f '"+voiceTestRemoteKey+"' && echo present || echo absent)\"; "+
			"printf 'status_marker=%s\\n' \"$(test -f '"+voiceTestRemoteOnceMarker+"' && echo armed || echo absent)\"; "+
			"printf 'session_marker=%s\\n' \"$(test -f '"+voiceTestRemoteSessionMarker+"' && echo armed || echo absent)\"; "+
			"printf 'link=%s\\n' \"$(test -L '"+voiceTestInitLink+"' && readlink '"+voiceTestInitLink+"' || echo absent)\"; "+
			"printf 'state=%s\\n' \"$(test -f '"+voiceTestRemoteState+"' && cat '"+voiceTestRemoteState+"' || echo absent)\"; "+
			"printf 'previous_state=%s\\n' \"$(test -f '"+voiceTestRemoteDir+"/previous-start.state' && cat '"+voiceTestRemoteDir+"/previous-start.state' || echo absent)\"; "+
			"echo 'media_log_begin'; test ! -f '"+voiceTestRemoteLog+"' || grep -E 'mavo-pcm-bridge|authenticated uplink' '"+voiceTestRemoteLog+"' || true; echo 'media_log_end'; "+
			"echo 'previous_media_log_begin'; test ! -f '"+voiceTestRemoteDir+"/previous-start.log' || tail -n 400 '"+voiceTestRemoteDir+"/previous-start.log'; echo 'previous_media_log_end'; "+
			"echo 'voice_runtime_begin'; grep -E '^qdc507_(aprv3|voice|incall_card) ' /proc/modules 2>/dev/null || true; readlink /sys/class/sound/card0/device/driver 2>/dev/null || true; cat /proc/asound/cards 2>/dev/null || true; cat /proc/asound/pcm 2>/dev/null || true; ls -l /dev/snd/controlC0 /dev/snd/pcmC0D4p /dev/snd/pcmC0D4c /dev/snd/pcmC0D5p /dev/snd/pcmC0D6c 2>&1 || true; test ! -f /run/mavo-alsaucm.log || tail -n 30 /run/mavo-alsaucm.log; echo 'voice_runtime_end'; "+
			"echo 'voice_mixer_begin'; command -v tinymix >/dev/null 2>&1 && tinymix 2>/dev/null | grep -E 'SEC_AUX_PCM_RX_Voice Mixer VoLTE|VoLTE_Tx Mixer SEC_AUX_PCM_TX_VoLTE|AFE_PCM_RX_Voice Mixer VoLTE|VoLTE_Tx Mixer AFE_PCM_TX_VoLTE|AFE_PCM_RX Audio Mixer MultiMedia1|Incall_Music Audio Mixer MultiMedia1' || true; echo 'voice_mixer_end'; "+
			"echo 'pcm0_begin'; for f in /proc/asound/card0/pcm0p/sub0/status /proc/asound/card0/pcm0p/sub0/hw_params /proc/asound/card0/pcm0p/sub0/sw_params; do echo \"[$f]\"; cat \"$f\" 2>&1 || true; done; echo 'pcm0_end'; "+
			"echo 'dapm_on_begin'; grep -H 'On' /sys/kernel/debug/asoc/*/dapm/* 2>/dev/null || true; echo 'dapm_on_end'; "+
			"echo 'kernel_audio_begin'; dmesg | grep -Ei 'audio|alsa|asoc|afe|apr|pcm|voice|q6' | tail -n 160; echo 'kernel_audio_end'; "+
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
	a.voiceTestArmAPI(w, r, voiceStatusOnceMode)
}

func (a *app) voiceTestArmSessionAPI(w http.ResponseWriter, r *http.Request) {
	a.voiceTestArmAPI(w, r, voiceControlSessionMode)
}

func (a *app) voiceTestArmAPI(w http.ResponseWriter, r *http.Request, mode voiceTestArmMode) {
	var request voiceTestArmRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm || request.ConfirmOperation != mode.confirmOperation {
		writeError(w, http.StatusBadRequest, "需要 confirm=true 且 confirm_operation="+mode.confirmOperation)
		return
	}
	data, artifactPath, err := loadVoiceDaemonArtifact(request.ArtifactPath)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var uplinkData []byte
	var aprv3Data []byte
	var voiceData []byte
	var incallCardData []byte
	var uplinkArtifactPath string
	var incallCardArtifactPath string
	if mode.purpose == voiceTestSessionPurpose {
		uplinkData, uplinkArtifactPath, err = loadVoiceUplinkArtifact(request.UplinkArtifactPath)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		aprv3Data, err = readUpstreamVoiceRuntimeFile("qdc507_aprv3.ko")
		if err != nil {
			writeError(w, http.StatusBadRequest, "缺少固定版本 qdc507_aprv3.ko: "+err.Error())
			return
		}
		voiceData, err = readUpstreamVoiceRuntimeFile("qdc507_voice.ko")
		if err != nil {
			writeError(w, http.StatusBadRequest, "缺少固定版本 qdc507_voice.ko: "+err.Error())
			return
		}
		incallCardData, incallCardArtifactPath, err = loadVoiceIncallCardArtifact(request.IncallCardArtifactPath)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
	}
	now := time.Now()
	var key []byte
	var stablePairingPath string
	if mode.purpose == voiceTestSessionPurpose {
		key, stablePairingPath, err = stableDevelopmentControlKey(
			request.PairingBundlePath, request.RotatePairing, now,
		)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "读取稳定开发 pairing key 失败: "+err.Error())
			return
		}
	} else {
		key = make([]byte, voiceControlTagBytes)
		if _, err := rand.Read(key); err != nil {
			writeError(w, http.StatusInternalServerError, "生成临时 pairing key 失败: "+err.Error())
			return
		}
	}
	defer func() {
		for index := range key {
			key[index] = 0
		}
	}()
	bundle, identifier, err := encodeDevelopmentPairingBundle(key, mode.purpose, now)
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
	if err := stopVoiceTestUplinkProcess(adb); err != nil {
		writeError(w, http.StatusBadGateway, "停止旧 PCM 上行监听失败: "+err.Error())
		return
	}
	armed := false
	defer func() {
		if !armed {
			_ = sentinelShell(adb, "rm -f '"+voiceTestRemoteKey+"' '"+voiceTestLegacyOnceMarker+"' '"+voiceTestRemoteOnceMarker+"' '"+voiceTestRemoteSessionMarker+"'", 8*time.Second)
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
	if len(uplinkData) != 0 {
		if err := adb.pushContext(r.Context(), uplinkData, voiceTestRemoteUplink, 0o100700, 30*time.Second); err != nil {
			writeError(w, http.StatusBadGateway, "推送 PCM 上行 bridge 失败: "+err.Error())
			return
		}
		if err := adb.pushContext(r.Context(), aprv3Data, voiceTestRemoteAPRv3, 0o100600, 30*time.Second); err != nil {
			writeError(w, http.StatusBadGateway, "推送 qdc507_aprv3.ko 失败: "+err.Error())
			return
		}
		if err := adb.pushContext(r.Context(), voiceData, voiceTestRemoteVoice, 0o100600, 30*time.Second); err != nil {
			writeError(w, http.StatusBadGateway, "推送 qdc507_voice.ko 失败: "+err.Error())
			return
		}
		if err := adb.pushContext(r.Context(), incallCardData, voiceTestRemoteIncallCard, 0o100600, 30*time.Second); err != nil {
			writeError(w, http.StatusBadGateway, "推送 QDC507 in-call card 失败: "+err.Error())
			return
		}
		if err := adb.pushContext(r.Context(), []byte(voiceTestPrepareIncallCardScript), voiceTestRemotePrepareCard, 0o100700, 15*time.Second); err != nil {
			writeError(w, http.StatusBadGateway, "推送 in-call card 准备脚本失败: "+err.Error())
			return
		}
	}
	if err := adb.pushContext(r.Context(), key, voiceTestRemoteKey, 0o100600, 15*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "推送测试 pairing key 失败: "+err.Error())
		return
	}
	if err := adb.pushContext(r.Context(), []byte(voiceTestStartScript), voiceTestRemoteScript, 0o100700, 15*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "推送测试启动脚本失败: "+err.Error())
		return
	}
	verify := "chmod 700 '" + voiceTestRemoteBinary + "' '" + voiceTestRemoteScript + "' && chmod 600 '" + voiceTestRemoteKey + "' && " +
		"test \"$(sha256sum '" + voiceTestRemoteBinary + "' | awk '{print $1}')\" = '" + voiceDaemonExpectedSHA256 + "' && " +
		"test \"$(wc -c < '" + voiceTestRemoteKey + "')\" = 32"
	if len(uplinkData) != 0 {
		verify += " && chmod 700 '" + voiceTestRemoteUplink + "' && " +
			"chmod 700 '" + voiceTestRemotePrepareCard + "' && " +
			"chmod 600 '" + voiceTestRemoteAPRv3 + "' '" + voiceTestRemoteVoice + "' && " +
			"chmod 600 '" + voiceTestRemoteIncallCard + "' && " +
			"test \"$(sha256sum '" + voiceTestRemoteUplink + "' | awk '{print $1}')\" = '" + voiceUplinkExpectedSHA256 + "' && " +
			"test \"$(sha256sum '" + voiceTestRemoteAPRv3 + "' | awk '{print $1}')\" = '" + voiceTestAPRv3ExpectedSHA256 + "' && " +
			"test \"$(sha256sum '" + voiceTestRemoteVoice + "' | awk '{print $1}')\" = '" + voiceTestVoiceExpectedSHA256 + "' && " +
			"test \"$(sha256sum '" + voiceTestRemoteIncallCard + "' | awk '{print $1}')\" = '" + voiceTestIncallCardExpectedSHA256 + "'"
	}
	if err := sentinelShell(adb, verify, 12*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "模块端测试文件校验失败: "+err.Error())
		return
	}
	if len(uplinkData) != 0 {
		check := "LD_LIBRARY_PATH=/usr/lib '" + voiceTestRemoteUplink + "' --check"
		if err := sentinelShell(adb, check, 12*time.Second); err != nil {
			writeError(w, http.StatusBadGateway, "PCM 上行 bridge 运行时符号预检失败: "+err.Error())
			return
		}
		if err := sentinelShell(adb, "'"+voiceTestRemoteScript+"' --prepare-only", 45*time.Second); err != nil {
			diagnostic, _, _ := adb.shellChecked(
				"readlink /sys/class/sound/card0/device/driver 2>/dev/null || true; cat /proc/asound/cards 2>/dev/null || true; cat /proc/asound/pcm 2>/dev/null || true; ls -l /dev/snd 2>&1 || true; "+
					"test ! -f /run/mavo-alsaucm.log || tail -n 80 /run/mavo-alsaucm.log; dmesg | tail -n 80",
				12*time.Second,
			)
			writeError(w, http.StatusBadGateway, "QDC507 voice runtime 预检失败: "+err.Error()+"; "+sentinelCleanShellOutput(diagnostic))
			return
		}
	}
	if err := startVoiceTestForValidation(adb); err != nil {
		writeError(w, http.StatusBadGateway, "认证 daemon 临时启动失败: "+err.Error())
		return
	}
	// Once the voice runtime is loaded, keeping libusb's ADB interface claimed
	// while dialing the ECM address can make macOS temporarily reject the
	// sibling network interface.  Release ADB for the authenticated TCP check,
	// then reconnect for owned-process cleanup and final marker installation.
	adb.Close()
	var reply voiceDaemonReply
	var queryErr error
	// Loading the QDC507 voice runtime can leave the sibling ECM interface
	// unreachable for a little over eight seconds on a cold module.  Keep the
	// daemon alive long enough for macOS to finish restoring that route before
	// deciding the authenticated STATUS check failed.
	preflightDeadline := time.Now().Add(voiceTestECMPreflightTimeout)
	for attempt := 0; attempt < 40 && time.Now().Before(preflightDeadline); attempt++ {
		reply, queryErr = queryTemporaryVoiceDaemon(key)
		if queryErr == nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	adb, err = openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, "认证 STATUS 后无法重新打开模块 ADB: "+err.Error())
		return
	}
	defer adb.Close()
	stopErr := stopVoiceTestProcess(adb)
	macECMUnavailable := mode.purpose == voiceTestSessionPurpose &&
		queryErr != nil && isVoiceDaemonDialUnavailable(queryErr)
	if (queryErr != nil && !macECMUnavailable) || reply.Status != 0 || stopErr != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("认证 STATUS 预检失败: query=%v status=%d stop=%v", queryErr, reply.Status, stopErr))
		return
	}
	if err := installVoiceTestLink(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := sentinelShell(adb,
		"rm -f '"+voiceTestRemoteState+"' '"+voiceTestRemoteLog+"' '"+voiceTestLegacyOnceMarker+"' '"+voiceTestRemoteOnceMarker+"' '"+voiceTestRemoteSessionMarker+"' && : > '"+mode.markerPath+"' && chmod 600 '"+mode.markerPath+"' && sync",
		8*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "设置一次性测试标记失败: "+err.Error())
		return
	}
	armed = true
	if mode.purpose == voiceTestSessionPurpose {
		a.moduleVoiceMu.Lock()
		a.moduleVoiceTestBypass = true
		a.moduleVoiceMu.Unlock()
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", "attachment; filename="+mode.filePrefix+identifier[:8]+".json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-DJOneHub-Artifact-Path", artifactPath)
	if uplinkArtifactPath != "" {
		w.Header().Set("X-DJOneHub-Uplink-Artifact-Path", uplinkArtifactPath)
	}
	if incallCardArtifactPath != "" {
		w.Header().Set("X-DJOneHub-Incall-Card-Artifact-Path", incallCardArtifactPath)
	}
	w.Header().Set("X-DJOneHub-Module-Identifier", identifier)
	if stablePairingPath != "" {
		w.Header().Set("X-DJOneHub-Stable-Pairing", stablePairingPath)
	}
	if macECMUnavailable {
		w.Header().Set("X-DJOneHub-Preflight", "listener-ready; mac-ecm-route-unavailable; require-ios-status")
	}
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
	if err := stopVoiceTestUplinkProcess(adb); err != nil {
		writeError(w, http.StatusBadGateway, "停止 PCM 上行监听失败: "+err.Error())
		return
	}
	cleanup := "if test -x '" + voiceTestRemotePrepareCard + "'; then '" + voiceTestRemotePrepareCard + "' --restore-stock || exit 1; fi; " +
		"rm -f '" + voiceTestLegacyOnceMarker + "' '" + voiceTestRemoteOnceMarker + "' '" + voiceTestRemoteSessionMarker + "' '" + voiceTestRemoteState + "' '" + voiceTestRemoteLog + "' '" +
		voiceTestRemoteScript + "' '" + voiceTestRemoteBinary + "' '" + voiceTestRemoteUplink + "' '" + voiceTestRemoteAPRv3 + "' '" + voiceTestRemoteVoice + "' '" + voiceTestRemoteIncallCard + "' '" + voiceTestRemotePrepareCard + "' '" + voiceTestRemoteKey + "' '" + voiceTestPIDFile + "' '" + voiceTestUplinkPIDFile + "'; " +
		"rmdir '" + voiceTestRemoteDir + "' 2>/dev/null || true; sync"
	if err := sentinelShell(adb, cleanup, 10*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "清理 iOS STATUS 测试失败: "+err.Error())
		return
	}
	a.moduleVoiceMu.Lock()
	a.moduleVoiceTestBypass = false
	a.moduleVoiceMu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"uninstalled": true})
}
