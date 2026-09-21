//go:build darwin && cgo

package main

import (
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
