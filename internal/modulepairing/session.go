package modulepairing

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	VoiceSessionLifetime = time.Hour
	sessionHeaderSize    = 8
	sessionRecordSize    = 40
)

type VoiceSession struct {
	Version    int    `json:"version"`
	Scope      string `json:"scope"`
	Credential string `json:"credential"`
	ExpiresAt  int64  `json:"expires_at"`
}

// SessionRegistry is a deliberately volatile bridge between long-term phone
// authorization and the small C voice daemon. The daemon receives only short-
// lived, voice-scoped keys; it never reads the durable authorization registry.
type SessionRegistry struct {
	Path string
	mu   sync.Mutex
}

func ReadVoiceSessionKey(path string, now time.Time) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return nil, ErrUnauthorized
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) != sessionHeaderSize+sessionRecordSize ||
		string(data[:4]) != "DJVS" || data[4] != 1 || data[5] != 1 ||
		data[6] != 0 || data[7] != 0 {
		return nil, ErrUnauthorized
	}
	expires := int64(binary.BigEndian.Uint64(data[8:16]))
	if expires <= now.Unix() {
		return nil, ErrUnauthorized
	}
	key := make([]byte, 32)
	copy(key, data[16:48])
	return key, nil
}

func (s *SessionRegistry) Issue(now time.Time) (VoiceSession, error) {
	if s == nil || s.Path == "" {
		return VoiceSession{}, ErrStorage
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if key, expires, err := readVoiceSession(s.Path, now); err == nil {
		credential := base64.RawURLEncoding.EncodeToString(key)
		for i := range key {
			key[i] = 0
		}
		return VoiceSession{Version: 1, Scope: "voice-control", Credential: credential, ExpiresAt: expires}, nil
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return VoiceSession{}, ErrStorage
	}
	expires := now.Add(VoiceSessionLifetime).Unix()
	// All authorized clients reuse the current short-lived voice session. This
	// keeps retries and concurrent app refreshes from invalidating a key that is
	// already in use. Explicit revocation still clears the session immediately.
	data := make([]byte, sessionHeaderSize+sessionRecordSize)
	copy(data[:4], "DJVS")
	data[4], data[5] = 1, 1
	binary.BigEndian.PutUint64(data[8:16], uint64(expires))
	copy(data[16:48], key)
	if err := writePrivateAtomic(s.Path, data); err != nil {
		return VoiceSession{}, ErrStorage
	}
	credential := base64.RawURLEncoding.EncodeToString(key)
	for i := range key {
		key[i] = 0
	}
	return VoiceSession{Version: 1, Scope: "voice-control", Credential: credential, ExpiresAt: expires}, nil
}

func readVoiceSession(path string, now time.Time) ([]byte, int64, error) {
	key, err := ReadVoiceSessionKey(path, now)
	if err != nil {
		return nil, 0, err
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) != sessionHeaderSize+sessionRecordSize {
		return nil, 0, ErrUnauthorized
	}
	return key, int64(binary.BigEndian.Uint64(data[8:16])), nil
}

func (s *SessionRegistry) Clear() error {
	if s == nil || s.Path == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	err := os.Remove(s.Path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return ErrStorage
	}
	return nil
}

func writePrivateAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(dir, ".voice-sessions-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err = temporary.Chmod(0600); err == nil {
		_, err = temporary.Write(data)
	}
	if err == nil {
		err = temporary.Sync()
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(name, path)
}
