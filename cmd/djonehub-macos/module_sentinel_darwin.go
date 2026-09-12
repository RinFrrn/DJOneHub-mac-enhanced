//go:build darwin && cgo

package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type sentinelInstallRequest struct {
	Confirm      bool   `json:"confirm"`
	ArtifactPath string `json:"artifact_path"`
}

func loadSentinelArtifact(path string) ([]byte, string, error) {
	if strings.TrimSpace(path) == "" {
		path = defaultSentinelArtifactPath()
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, "", fmt.Errorf("无法解析 sentinel 路径: %w", err)
	}
	info, err := os.Lstat(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("无法读取 sentinel: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, "", fmt.Errorf("sentinel 必须是普通文件，不能是符号链接")
	}
	if info.Size() <= 0 || info.Size() > sentinelMaximumSize {
		return nil, "", fmt.Errorf("sentinel 文件大小无效：%d bytes", info.Size())
	}
	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, "", fmt.Errorf("读取 sentinel 失败: %w", err)
	}
	if err := validateSentinelArtifact(data); err != nil {
		return nil, "", err
	}
	return data, absPath, nil
}

func sentinelRequireRoot(adb *adbClient) error {
	out, status, err := adb.shellChecked("id -u", 8*time.Second)
	if err != nil {
		return fmt.Errorf("ADB 探测失败: %w", err)
	}
	cleanOut := sentinelCleanShellOutput(out)
	fields := strings.Fields(cleanOut)
	if status != 0 || len(fields) == 0 || fields[0] != "0" {
		return fmt.Errorf("模块 ADB 不是 root（id -u 返回 %q）", cleanOut)
	}
	return nil
}

func sentinelShell(adb *adbClient, command string, timeout time.Duration) error {
	out, status, err := adb.shellChecked(command, timeout)
	if err != nil {
		return err
	}
	if status != 0 {
		detail := sentinelCleanShellOutput(out)
		if detail == "" {
			detail = fmt.Sprintf("exit status %d", status)
		}
		return fmt.Errorf("%s", detail)
	}
	return nil
}

func sentinelValidateTemporary(adb *adbClient) error {
	command := "rm -f '" + sentinelPIDFile + "' '" + sentinelLogFile + "'; " +
		"owned() { " +
		"test -n \"$pid\" && test -d \"/proc/$pid\" && " +
		"argv0=$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p') && " +
		"test \"$argv0\" = '" + sentinelRemoteBinary + "'; }; " +
		"cleanup() { owned && kill -TERM \"$pid\" 2>/dev/null || true; " +
		"rm -f '" + sentinelPIDFile + "'; }; " +
		"trap cleanup EXIT HUP INT TERM; " +
		"nohup '" + sentinelRemoteBinary + "' --listen-address 192.168.225.1 --port 45750 " +
		"</dev/null >> '" + sentinelLogFile + "' 2>&1 & pid=$!; " +
		"printf '%s\\n' \"$pid\" > '" + sentinelPIDFile + "' && " +
		"sleep 1 && owned && " +
		"awk '$2 ~ /:B2B6$/ && $4 == \"0A\" { found=1 } END { exit found ? 0 : 1 }' /proc/net/tcp"
	if err := sentinelShell(adb, command, 12*time.Second); err != nil {
		logText, _, _ := adb.shellChecked("test ! -f '"+sentinelLogFile+"' || tail -n 80 '"+sentinelLogFile+"'", 8*time.Second)
		return fmt.Errorf("sentinel 临时运行验证失败: %v；日志：%s", err, sentinelCleanShellOutput(logText))
	}
	return nil
}

func sentinelInstallInitLink(adb *adbClient) error {
	out, status, err := adb.shellChecked(
		"if test -L '"+sentinelInitLink+"'; then readlink '"+sentinelInitLink+"'; "+
			"elif test -e '"+sentinelInitLink+"'; then echo __CONFLICT__; else echo __ABSENT__; fi",
		8*time.Second,
	)
	if err != nil || status != 0 {
		return fmt.Errorf("检查启动链接失败: %v %s", err, sentinelCleanShellOutput(out))
	}
	linkState := sentinelCleanShellOutput(out)
	if linkState != "__ABSENT__" && linkState != sentinelRemoteScript {
		return fmt.Errorf("拒绝覆盖已有启动项 %s（当前：%s）", sentinelInitLink, linkState)
	}
	if linkState == sentinelRemoteScript {
		return nil
	}
	if err := sentinelShell(adb, sentinelInstallLinkCommand(), 15*time.Second); err != nil {
		return fmt.Errorf("安装一次性启动链接失败: %w", err)
	}
	return nil
}

func sentinelRemoveInitLink(adb *adbClient) error {
	out, status, err := adb.shellChecked(
		"if test -L '"+sentinelInitLink+"'; then readlink '"+sentinelInitLink+"'; "+
			"elif test -e '"+sentinelInitLink+"'; then echo __CONFLICT__; else echo __ABSENT__; fi",
		8*time.Second,
	)
	if err != nil || status != 0 {
		return fmt.Errorf("检查启动链接失败: %v %s", err, sentinelCleanShellOutput(out))
	}
	linkState := sentinelCleanShellOutput(out)
	if linkState == "__ABSENT__" {
		return nil
	}
	if linkState != sentinelRemoteScript {
		return fmt.Errorf("拒绝删除非 DJOneHub 启动项 %s（当前：%s）", sentinelInitLink, linkState)
	}
	if err := sentinelShell(adb, sentinelRemoveLinkCommand(), 15*time.Second); err != nil {
		return fmt.Errorf("删除一次性启动链接失败: %w", err)
	}
	return nil
}

func sentinelStopOwnedProcess(adb *adbClient) error {
	command := "if test -s '" + sentinelPIDFile + "'; then " +
		"read pid < '" + sentinelPIDFile + "' || true; " +
		"case \"$pid\" in ''|*[!0-9]*) true;; *) " +
		"owned() { test -d \"/proc/$pid\" && " +
		"test \"$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p')\" = '" + sentinelRemoteBinary + "'; }; " +
		"if owned; then kill -TERM \"$pid\" 2>/dev/null || true; " +
		"attempt=0; while owned && test \"$attempt\" -lt 30; do sleep 0.1; attempt=$((attempt + 1)); done; " +
		"owned && exit 1 || true; fi;; esac; fi; rm -f '" + sentinelPIDFile + "'"
	if err := sentinelShell(adb, command, 8*time.Second); err != nil {
		return fmt.Errorf("停止 sentinel 进程失败: %w", err)
	}
	return nil
}

func (a *app) sentinelStatusAPI(w http.ResponseWriter, _ *http.Request) {
	a.moduleVoiceOpMu.Lock()
	defer a.moduleVoiceOpMu.Unlock()
	adb, err := openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer adb.Close()
	out, status, err := adb.shellChecked(
		"printf 'binary=%s\\n' \"$(test -x '"+sentinelRemoteBinary+"' && echo yes || echo no)\"; "+
			"printf 'marker=%s\\n' \"$(test -f '"+sentinelRemoteMarker+"' && echo armed || echo absent)\"; "+
			"printf 'link=%s\\n' \"$(test -L '"+sentinelInitLink+"' && readlink '"+sentinelInitLink+"' || echo absent)\"; "+
			"printf 'last_start_state=%s\\n' \"$(test -f '"+sentinelBootStateFile+"' && cat '"+sentinelBootStateFile+"' || echo absent)\"; "+
			"echo 'last_start_log_begin'; test ! -f '"+sentinelBootLogFile+"' || tail -n 80 '"+sentinelBootLogFile+"'; "+
			"echo 'last_start_log_end'",
		8*time.Second,
	)
	if err != nil || status != 0 {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("读取 sentinel 状态失败: %v %s", err, sentinelCleanShellOutput(out)))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"expected_sha256": sentinelExpectedSHA256,
		"artifact_path":   defaultSentinelArtifactPath(),
		"detail":          sentinelCleanShellOutput(out),
	})
}

func (a *app) sentinelInstallOnceAPI(w http.ResponseWriter, r *http.Request) {
	var request sentinelInstallRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm {
		writeError(w, http.StatusBadRequest, "需要明确确认一次性持久启动")
		return
	}
	data, artifactPath, err := loadSentinelArtifact(request.ArtifactPath)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	log.Printf("sentinel install: waiting for module operation lock")
	a.moduleVoiceOpMu.Lock()
	defer a.moduleVoiceOpMu.Unlock()
	log.Printf("sentinel install: module operation lock acquired")
	adb, err := openDJIUSBADB()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer adb.Close()
	log.Printf("sentinel install: USB ADB opened")
	if err := sentinelRequireRoot(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	log.Printf("sentinel install: module root confirmed")
	if err := sentinelShell(adb,
		"test -d /usrdata && mkdir -p '"+sentinelRemoteDir+"' && chmod 700 '"+sentinelRemoteDir+"'",
		8*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "准备 /usrdata 目录失败: "+err.Error())
		return
	}
	log.Printf("sentinel install: pushing binary (%d bytes)", len(data))
	if err := adb.pushContext(r.Context(), data, sentinelRemoteBinary, 0o100755, 30*time.Second); err != nil {
		log.Printf("sentinel install: binary push failed: %v", err)
		writeError(w, http.StatusBadGateway, "推送 sentinel 失败: "+err.Error())
		return
	}
	log.Printf("sentinel install: binary pushed")
	if err := adb.pushContext(r.Context(), []byte(sentinelStartOnceScript), sentinelRemoteScript, 0o100755, 15*time.Second); err != nil {
		log.Printf("sentinel install: start script push failed: %v", err)
		writeError(w, http.StatusBadGateway, "推送启动脚本失败: "+err.Error())
		return
	}
	log.Printf("sentinel install: start script pushed")
	verify := "chmod 755 '" + sentinelRemoteBinary + "' '" + sentinelRemoteScript + "' && " +
		"test \"$(sha256sum '" + sentinelRemoteBinary + "' | awk '{print $1}')\" = '" + sentinelExpectedSHA256 + "'"
	if err := sentinelShell(adb, verify, 12*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "模块端 sentinel 校验失败: "+err.Error())
		return
	}
	log.Printf("sentinel install: module hashes verified")
	if err := sentinelValidateTemporary(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	log.Printf("sentinel install: temporary listener verified")
	if err := sentinelInstallInitLink(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	log.Printf("sentinel install: init link installed")
	if err := sentinelShell(adb,
		"rm -f '"+sentinelBootStateFile+"' '"+sentinelBootLogFile+"' && "+
			": > '"+sentinelRemoteMarker+"' && chmod 600 '"+sentinelRemoteMarker+"' && sync",
		8*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "设置一次性启动标记失败: "+err.Error())
		return
	}
	log.Printf("sentinel install: armed for one boot")
	writeJSON(w, http.StatusOK, map[string]any{
		"installed":       true,
		"armed_once":      true,
		"artifact_path":   artifactPath,
		"sha256":          sentinelExpectedSHA256,
		"remote_binary":   sentinelRemoteBinary,
		"remote_init_link": sentinelInitLink,
	})
}

func (a *app) sentinelUninstallAPI(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Confirm bool `json:"confirm"`
	}
	if !decodeJSON(w, r, &request) {
		return
	}
	if !request.Confirm {
		writeError(w, http.StatusBadRequest, "需要明确确认卸载 sentinel")
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
	if err := sentinelRemoveInitLink(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := sentinelStopOwnedProcess(adb); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	cleanup := "rm -f '" + sentinelRemoteMarker + "' '" + sentinelBootStateFile + "' '" +
		sentinelBootLogFile + "' '" + sentinelRemoteScript + "' '" + sentinelRemoteBinary + "' '" + sentinelPIDFile + "'; " +
		"rmdir '" + sentinelRemoteDir + "' 2>/dev/null || true; sync"
	if err := sentinelShell(adb, cleanup, 10*time.Second); err != nil {
		writeError(w, http.StatusBadGateway, "清理 sentinel 文件失败: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"uninstalled": true})
}
