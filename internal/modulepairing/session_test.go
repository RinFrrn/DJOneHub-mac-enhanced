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
	loaded, err := ReadVoiceSessionKey(path, now)
	if err != nil || string(loaded) != string(key) {
		t.Fatal("could not load active voice session")
	}
	if _, err := ReadVoiceSessionKey(path, now.Add(VoiceSessionLifetime)); err == nil {
		t.Fatal("expired voice session was accepted")
	}
	if err := registry.Clear(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("session survived clear")
	}
}

func TestVoiceSessionRegistryReusesUnexpiredSession(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	registry := SessionRegistry{Path: filepath.Join(t.TempDir(), "voice-sessions.v1")}
	first, err := registry.Issue(now)
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.Issue(now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if second.Credential != first.Credential || second.ExpiresAt != first.ExpiresAt {
		t.Fatal("unexpired session was unexpectedly rotated")
	}
	third, err := registry.Issue(now.Add(VoiceSessionLifetime))
	if err != nil {
		t.Fatal(err)
	}
	if third.Credential == first.Credential || third.ExpiresAt <= first.ExpiresAt {
		t.Fatal("expired session was not replaced")
	}
}
