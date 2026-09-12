package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/iniwex5/vohive/internal/modulepairing"
)

func TestPrepareCreatesIndependentPrivateArtifactsWithoutOverwriting(t *testing.T) {
	path := filepath.Join(t.TempDir(), "module")
	if err := prepare(path, time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"registry.json", "bootstrap.json", "recovery.json"} {
		info, err := os.Stat(filepath.Join(path, name))
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatal("artifact not private", name, err)
		}
	}
	var bootstrap, recovery modulepairing.Invitation
	data, _ := os.ReadFile(filepath.Join(path, "bootstrap.json"))
	if err := json.Unmarshal(data, &bootstrap); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(filepath.Join(path, "recovery.json"))
	if err := json.Unmarshal(data, &recovery); err != nil {
		t.Fatal(err)
	}
	if bootstrap.ModuleID != recovery.ModuleID || bootstrap.CertificateSHA256 != recovery.CertificateSHA256 || bootstrap.Secret == recovery.Secret {
		t.Fatal("invalid provisioning artifacts")
	}
	before, _ := os.ReadFile(filepath.Join(path, "registry.json"))
	if err := prepare(path, time.Now()); err == nil {
		t.Fatal("existing module overwritten")
	}
	after, _ := os.ReadFile(filepath.Join(path, "registry.json"))
	if string(before) != string(after) {
		t.Fatal("failed provisioning modified identity")
	}
}
