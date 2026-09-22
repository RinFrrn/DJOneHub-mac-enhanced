//go:build darwin && cgo

package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/iniwex5/vohive/internal/modulepairing"
	"github.com/iniwex5/vohive/internal/modulepush"
)

func runModuleNotify(options moduleNotifyOptions) error {
	if options.Action == "install-authorization" {
		return installModuleAuthorization(options.PairingRegistryPath)
	}
	if options.Action == "update-authorization-runtime" {
		return updateModuleAuthorizationRuntime(options.ArtifactDir)
	}
	if options.Action != "install" {
		command, err := moduleNotifyCommand(options.Action)
		if err != nil {
			return err
		}
		adb, err := openDJIUSBADB()
		if err != nil {
			return err
		}
		defer adb.Close()
		if err := sentinelRequireRoot(adb); err != nil {
			return err
		}
		timeout := 30 * time.Second
		if options.Action == "probe-runtime" {
			timeout = 50 * time.Second
		}
		out, status, err := adb.shellChecked(command, timeout)
		if err != nil {
			return err
		}
		// Commands never include credentials and sender errors are redacted.
		fmt.Println(sentinelCleanShellOutput(out))
		if status != 0 {
			return fmt.Errorf("module notification action failed (exit %d)", status)
		}
		return nil
	}
	var config modulepush.Config
	if err := modulepush.ReadPrivateJSON(options.ConfigPath, &config); err != nil {
		return err
	}
	if err := config.Validate(); err != nil {
		return err
	}
	configData, err := os.ReadFile(options.ConfigPath)
	if err != nil {
		return err
	}
	ca, err := os.ReadFile(options.CAPath)
	if err != nil {
		return err
	}
	if !strings.Contains(string(ca), "BEGIN CERTIFICATE") || strings.Contains(string(ca), "PRIVATE KEY") {
		return errors.New("expected a public CA certificate bundle")
	}
	files := map[string][]byte{"config.json": configData, "ca.pem": ca, "start-on-boot.sh": []byte(moduleNotifyStartScript)}
	for _, name := range []string{"djonehub-notify.armv7", "djonehub-notify-monitor.armv7"} {
		data, err := os.ReadFile(filepath.Join(options.ArtifactDir, name))
		if err != nil {
			return err
		}
		// ELF32, little endian, EM_ARM; full ABI validation belongs to build.
		if len(data) < 20 || string(data[:4]) != "\x7fELF" || data[4] != 1 || data[5] != 1 || data[18] != 40 || data[19] != 0 {
			return errors.New("expected ARM ELF notification artifact")
		}
		files[name] = data
	}
	adb, err := openDJIUSBADB()
	if err != nil {
		return err
	}
	defer adb.Close()
	var totalBytes int64
	for _, data := range files {
		totalBytes += int64(len(data))
	}
	requiredKB := moduleNotifyRequiredKB(totalBytes)
	if err := sentinelShell(adb, moduleNotifyInstallPreflight(requiredKB), 10*time.Second); err != nil {
		return fmt.Errorf("QDC507 preflight failed (requires %d KiB free /usrdata): %w", requiredKB, err)
	}
	// A running process keeps its files; stop explicitly before replacing them.
	statusCommand, _ := moduleNotifyCommand("status")
	out, status, err := adb.shellChecked(statusCommand, 5*time.Second)
	if err != nil || status != 0 {
		return errors.New("cannot establish notification process state")
	}
	if strings.TrimSpace(sentinelCleanShellOutput(out)) == "running" {
		return errors.New("stop the notification daemon before installing an update")
	}
	// Stage every file before replacing any installed file. The root filesystem
	// is touched only after the private /usrdata installation is complete.
	for _, name := range []string{"djonehub-notify.armv7", "djonehub-notify-monitor.armv7", "ca.pem", "config.json", "start-on-boot.sh"} {
		data := files[name]
		remote := moduleNotifyDir + "/" + name + ".new"
		if err := adb.push(data, remote, 0100600, 90*time.Second); err != nil {
			return errors.New("notification artifact upload failed")
		}
		adb.connected = false
		digest := sha256.Sum256(data)
		if err := sentinelShell(adb, fmt.Sprintf("chmod 600 '%s' && test \"$(sha256sum '%s' | cut -d ' ' -f 1)\" = '%x'", remote, remote, digest), 10*time.Second); err != nil {
			return errors.New("notification artifact verification failed")
		}
	}
	check := "GOMEMLIMIT=6MiB GOGC=25 GOMAXPROCS=1 " + moduleNotifyDir + "/djonehub-notify.armv7.new -config " + moduleNotifyDir + "/config.json.new -check"
	if err := sentinelShell(adb, "chmod 700 "+moduleNotifyDir+"/djonehub-notify.armv7.new "+moduleNotifyDir+"/djonehub-notify-monitor.armv7.new "+moduleNotifyDir+"/start-on-boot.sh.new && "+check, 20*time.Second); err != nil {
		return fmt.Errorf("module notification preflight failed: %w", err)
	}
	var commit []string
	for _, name := range []string{"djonehub-notify.armv7", "djonehub-notify-monitor.armv7", "ca.pem", "config.json", "start-on-boot.sh"} {
		commit = append(commit, "mv '"+moduleNotifyDir+"/"+name+".new' '"+moduleNotifyDir+"/"+name+"'")
	}
	if err := sentinelShell(adb, strings.Join(commit, " && "), 10*time.Second); err != nil {
		return err
	}
	if err := sentinelShell(adb, moduleNotifyInstallLinkCommand(), 15*time.Second); err != nil {
		return fmt.Errorf("notification files installed, but boot service could not be enabled: %w", err)
	}
	fmt.Println("Installed module notifications and enabled boot startup. Run test-bark or test-webpush, then start.")
	return nil
}

func updateModuleAuthorizationRuntime(artifactDir string) error {
	files := []struct {
		local, remote string
		mode          uint32
		data          []byte
	}{
		{filepath.Join(artifactDir, "djonehub-notify.armv7"), moduleNotifyDir + "/djonehub-notify.armv7", 0100700, nil},
		{filepath.Join(artifactDir, "djonehub-notify-monitor.armv7"), moduleNotifyDir + "/djonehub-notify-monitor.armv7", 0100700, nil},
		{filepath.Join(artifactDir, "djonehub-voice-daemon.armv7"), voiceTestRemoteBinary, 0100700, nil},
		{"", moduleNotifyDir + "/start-on-boot.sh", 0100700, []byte(moduleNotifyStartScript)},
		{"", voiceTestRemoteScript, 0100700, []byte(voiceTestStartScript)},
	}
	for index := range files {
		if files[index].data != nil {
			continue
		}
		data, err := os.ReadFile(files[index].local)
		if err != nil {
			return err
		}
		if len(data) < 20 || string(data[:4]) != "\x7fELF" || data[18] != 40 || data[19] != 0 {
			return fmt.Errorf("expected ARM ELF artifact: %s", files[index].local)
		}
		files[index].data = data
	}
	adb, err := openDJIUSBADB()
	if err != nil {
		return err
	}
	defer adb.Close()
	if err := sentinelRequireRoot(adb); err != nil {
		return err
	}
	preflight := "test -s '" + moduleNotifyDir + "/config.json' && test -s '/usrdata/djonehub/pairing/registry.json' && test -s '" + voiceTestRemoteKey + "' && test \"$(wc -c < '" + voiceTestRemoteKey + "')\" = 32"
	if err := sentinelShell(adb, preflight, 10*time.Second); err != nil {
		return errors.New("模块缺少现有配置、长期身份或通话密钥；拒绝更新")
	}
	legacyBackup := moduleNotifyDir + "/djonehub-notify.armv7.before-bark"
	if data, pullErr := adb.pull(legacyBackup, 9*1024*1024, 120*time.Second); pullErr == nil && len(data) > 0 {
		localBackup := filepath.Join(artifactDir, "djonehub-notify.armv7.before-bark.module-backup")
		if err := os.WriteFile(localBackup, data, 0600); err != nil {
			return err
		}
		if err := sentinelShell(adb, "rm -f '"+legacyBackup+"'", 10*time.Second); err != nil {
			return err
		}
	}
	var cleanup []string
	for _, file := range files {
		cleanup = append(cleanup, "rm -f '"+file.remote+".session-new' '"+file.remote+".session-new.gz' '"+file.remote+".before-session-auth'")
	}
	cleanup = append(cleanup, "if test -f '"+moduleNotifyDir+"/djonehub-notify.armv7.before-bark' && test \"$(sha256sum '"+moduleNotifyDir+"/djonehub-notify.armv7.before-bark' | cut -d ' ' -f 1)\" = \"$(sha256sum '"+moduleNotifyDir+"/djonehub-notify.armv7' | cut -d ' ' -f 1)\"; then rm -f '"+moduleNotifyDir+"/djonehub-notify.armv7.before-bark'; fi")
	if err := sentinelShell(adb, strings.Join(cleanup, " && "), 10*time.Second); err != nil {
		return err
	}
	for index := range files {
		staged := files[index].remote + ".session-new"
		payload, uploadPath := files[index].data, staged
		compressed := bytes.Buffer{}
		if files[index].local != "" {
			writer := gzip.NewWriter(&compressed)
			if _, err := writer.Write(payload); err != nil {
				return err
			}
			if err := writer.Close(); err != nil {
				return err
			}
			payload, uploadPath = compressed.Bytes(), staged+".gz"
		}
		if err := adb.push(payload, uploadPath, 0100600, 90*time.Second); err != nil {
			return fmt.Errorf("上传运行时失败 %s: %w", filepath.Base(files[index].remote), err)
		}
		adb.connected = false
		digest := sha256.Sum256(files[index].data)
		prepare := ""
		if uploadPath != staged {
			prepare = "gzip -dc '" + uploadPath + "' > '" + staged + "' && rm -f '" + uploadPath + "' && "
		}
		if err := sentinelShell(adb, prepare+fmt.Sprintf("chmod %o '%s' && test \"$(sha256sum '%s' | cut -d ' ' -f 1)\" = '%x'", files[index].mode&0777, staged, staged, digest), 30*time.Second); err != nil {
			return fmt.Errorf("模块端运行时校验失败；原服务未改动: %w", err)
		}
	}
	stopNotify, _ := moduleNotifyCommand("stop")
	if err := sentinelShell(adb, stopNotify, 15*time.Second); err != nil {
		return err
	}
	if err := stopVoiceTestProcess(adb); err != nil {
		return err
	}
	for _, file := range files {
		current, pullErr := adb.pull(file.remote, 9*1024*1024, 120*time.Second)
		if pullErr != nil || len(current) == 0 {
			return fmt.Errorf("无法备份当前运行时: %s", filepath.Base(file.remote))
		}
		backupName := filepath.Base(file.remote) + ".before-session-auth.module-backup"
		if err := os.WriteFile(filepath.Join(artifactDir, backupName), current, 0600); err != nil {
			return err
		}
	}
	var commit []string
	for _, file := range files {
		commit = append(commit, "rm -f '"+file.remote+".before-session-auth'", "mv '"+file.remote+".session-new' '"+file.remote+"'")
	}
	commit = append(commit, "sync")
	if err := sentinelShell(adb, strings.Join(commit, " && "), 30*time.Second); err != nil {
		return errors.New("提交运行时失败；模块保留了 before-session-auth 备份")
	}
	check := "GOMEMLIMIT=6MiB GOGC=25 GOMAXPROCS=1 '" + moduleNotifyDir + "/djonehub-notify.armv7' -config '" + moduleNotifyDir + "/config.json' -check"
	if err := sentinelShell(adb, check, 20*time.Second); err != nil {
		return fmt.Errorf("新提醒服务预检失败: %w", err)
	}
	startNotify, _ := moduleNotifyCommand("start")
	if err := sentinelShell(adb, startNotify, 15*time.Second); err != nil {
		return err
	}
	if err := sentinelShell(adb, "nohup setsid '"+voiceTestRemoteScript+"' </dev/null >/tmp/djonehub-session-launch.log 2>&1 & sleep 2; test -f '"+voiceTestRemoteState+"'", 12*time.Second); err != nil {
		return fmt.Errorf("新电话服务启动失败: %w", err)
	}
	fmt.Println("Updated authorization runtime; existing identity, recovery authority, notification config and legacy call key were preserved.")
	return nil
}

func installModuleAuthorization(registryPath string) error {
	if strings.TrimSpace(registryPath) == "" {
		return errors.New("长期授权安装需要 -notify-pairing-registry")
	}
	absPath, err := filepath.Abs(registryPath)
	if err != nil {
		return errors.New("无法解析长期授权注册表路径")
	}
	info, err := os.Lstat(absPath)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return errors.New("长期授权注册表必须是权限 0600 的普通文件")
	}
	store, err := modulepairing.Open(absPath)
	if err != nil {
		return fmt.Errorf("长期授权注册表无效: %w", err)
	}
	if _, err = store.TLSConfig(); err != nil {
		store.Close()
		return fmt.Errorf("模块 TLS 身份无效: %w", err)
	}
	store.Close()
	registryData, err := os.ReadFile(absPath)
	if err != nil {
		return err
	}
	scriptData := []byte(moduleNotifyStartScript)
	adb, err := openDJIUSBADB()
	if err != nil {
		return err
	}
	defer adb.Close()
	if err := sentinelRequireRoot(adb); err != nil {
		return err
	}
	if err := sentinelShell(adb,
		"test ! -e '/usrdata/djonehub/pairing/registry.json' && "+
			"test -x '"+moduleNotifyDir+"/djonehub-notify.armv7' && "+
			"strings '"+moduleNotifyDir+"/djonehub-notify.armv7' | grep -q 'experimental-pairing-registry' && "+
			"mkdir -p '/usrdata/djonehub/pairing' && chmod 700 '/usrdata/djonehub/pairing'",
		10*time.Second); err != nil {
		return errors.New("模块已有长期身份，或当前提醒程序不支持长期授权；已拒绝覆盖")
	}
	stop, _ := moduleNotifyCommand("stop")
	if err := sentinelShell(adb, stop, 15*time.Second); err != nil {
		return fmt.Errorf("停止提醒服务失败: %w", err)
	}
	for _, file := range []struct {
		data []byte
		path string
	}{
		{registryData, "/usrdata/djonehub/pairing/registry.json.new"},
		{scriptData, moduleNotifyDir + "/start-on-boot.sh.new"},
	} {
		if err := adb.push(file.data, file.path, 0100600, 30*time.Second); err != nil {
			return errors.New("长期授权文件上传失败；原服务可直接重新启动")
		}
		digest := sha256.Sum256(file.data)
		if err := sentinelShell(adb, fmt.Sprintf(
			"chmod 600 '%s' && test \"$(sha256sum '%s' | cut -d ' ' -f 1)\" = '%x'",
			file.path, file.path, digest), 10*time.Second); err != nil {
			return errors.New("长期授权文件校验失败；原服务可直接重新启动")
		}
	}
	commit := "cp '" + moduleNotifyDir + "/start-on-boot.sh' '" + moduleNotifyDir + "/start-on-boot.sh.before-authorization' && " +
		"mv '/usrdata/djonehub/pairing/registry.json.new' '/usrdata/djonehub/pairing/registry.json' && " +
		"mv '" + moduleNotifyDir + "/start-on-boot.sh.new' '" + moduleNotifyDir + "/start-on-boot.sh' && " +
		"chmod 600 '/usrdata/djonehub/pairing/registry.json' && chmod 700 '" + moduleNotifyDir + "/start-on-boot.sh' && sync"
	if err := sentinelShell(adb, commit, 12*time.Second); err != nil {
		return fmt.Errorf("提交长期授权身份失败: %w", err)
	}
	start, _ := moduleNotifyCommand("start")
	if err := sentinelShell(adb, start, 15*time.Second); err != nil {
		return errors.New("长期授权已安装，但提醒服务启动失败；请保留初始化资料并检查模块日志")
	}
	adb.Close()
	connection, err := net.DialTimeout("tcp4", net.JoinHostPort(modulepairing.Host, fmt.Sprint(modulepairing.Port)), 5*time.Second)
	if err != nil {
		return errors.New("提醒服务已启动，但长期授权端口尚不可达")
	}
	connection.Close()
	fmt.Println("Installed module long-term identity. Existing call, SMS, audio and notification pairing was preserved.")
	return nil
}
