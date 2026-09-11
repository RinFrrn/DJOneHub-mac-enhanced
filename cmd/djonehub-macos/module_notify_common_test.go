package main

import (
	"os/exec"
	"strings"
	"testing"
)

func TestModuleNotifyCommandsAreFixedAndValidShell(t *testing.T) {
	commands := []string{moduleNotifyInstallPreflight(8192)}
	for _, action := range []string{"start", "stop", "status", "test-bark", "test-webpush", "probe-network", "probe-runtime", "enable-boot", "disable-boot"} {
		command, err := moduleNotifyCommand(action)
		if err != nil {
			t.Fatal(err)
		}
		commands = append(commands, command)
	}
	for _, command := range commands {
		cmd := exec.Command("sh", "-n")
		cmd.Stdin = strings.NewReader(command)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("invalid shell: %s %v", out, err)
		}
		if strings.Contains(command, "/tmp/") {
			t.Fatal("notification runtime must use /usrdata")
		}
	}
	if _, err := moduleNotifyCommand("start; reboot"); err == nil {
		t.Fatal("accepted non-allowlisted command")
	}
}

func TestModuleNotifyBootCommandsRestoreReadOnlyRoot(t *testing.T) {
	for _, command := range []string{moduleNotifyInstallLinkCommand(), moduleNotifyRemoveLinkCommand()} {
		if !strings.Contains(command, "trap restore_ro") ||
			!strings.Contains(command, "mount -o remount,ro /") ||
			!strings.Contains(command, moduleNotifyInitLink) {
			t.Fatal("unsafe boot link command", command)
		}
	}
	cmd := exec.Command("sh", "-n")
	cmd.Stdin = strings.NewReader(moduleNotifyStartScript)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("invalid boot script: %s %v", out, err)
	}
}
