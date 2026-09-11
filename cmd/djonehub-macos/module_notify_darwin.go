//go:build darwin && cgo

package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/iniwex5/vohive/internal/modulepush"
)

func runModuleNotify(options moduleNotifyOptions) error {
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
