package modulepairing

import (
	"encoding/base64"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestVoiceSessionRegistryIsPrivateAndVolatile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "run", "voice-sessions.v1")
	registry := &SessionRegistry{Path: path}
	now := time.Unix(2_000_000_000, 0)
	session, err := registry.Issue(now)
	if err != nil {
		t.Fatal(err)
	}
	key, err := base64.RawURLEncoding.DecodeString(session.Credential)
	if err != nil || len(key) != 32 || session.Scope != "voice-control" ||
		session.ExpiresAt != now.Add(VoiceSessionLifetime).Unix() {
		t.Fatal("invalid issued session")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 || len(data) != 48 ||
		string(data[:4]) != "DJVS" || data[4] != 1 || data[5] != 1 ||
		int64(binary.BigEndian.Uint64(data[8:16])) != session.ExpiresAt ||
		string(data[16:]) != string(key) {
		t.Fatal("invalid private session registry")
	}
	if err := registry.Clear(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("session survived clear")
	}
}
