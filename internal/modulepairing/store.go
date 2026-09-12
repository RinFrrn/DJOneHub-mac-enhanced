// Package modulepairing owns the durable authorization registry for a module.
// It deliberately does not accept or export legacy voice pairing keys.
package modulepairing

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

const (
	Version           = 1
	Host              = "192.168.225.1"
	Port              = 45754
	MaxDevices        = 4
	BootstrapLifetime = 15 * time.Minute
	PendingLifetime   = 10 * time.Minute
)

var (
	ErrUnauthorized = errors.New("module authorization failed")
	ErrInvalid      = errors.New("invalid module authorization request")
	ErrConflict     = errors.New("another authorization change is pending")
	ErrCapacity     = errors.New("module device limit reached")
	ErrStorage      = errors.New("module authorization storage unavailable")
)

// Secret is a canonical, randomly generated 256-bit capability. Only its hash
// is retained by the module. Never include a Secret in diagnostics.
func NewSecret() (string, error) {
	var bytes [32]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes[:]), nil
}

func secretHash(secret string) (string, error) {
	bytes, err := base64.RawURLEncoding.Strict().DecodeString(secret)
	if err != nil || len(bytes) != 32 || base64.RawURLEncoding.EncodeToString(bytes) != secret {
		return "", ErrInvalid
	}
	hash := sha256.Sum256(bytes)
	return hex.EncodeToString(hash[:]), nil
}

func matches(secret, hash string) bool {
	actual, err := secretHash(secret)
	return err == nil && len(hash) == 64 && subtle.ConstantTimeCompare([]byte(actual), []byte(hash)) == 1
}

type Device struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	CreatedAt int64  `json:"created_at"`
}

type deviceRecord struct {
	Device
	Hash string `json:"hash"`
}

type pendingRecord struct {
	Device        deviceRecord `json:"device"`
	Kind          string       `json:"kind"`
	AuthorityHash string       `json:"authority_hash"`
	RecoveryHash  string       `json:"recovery_hash,omitempty"`
	ExpiresAt     int64        `json:"expires_at"`
}

type diskState struct {
	Version            int            `json:"version"`
	ModuleID           string         `json:"module_id"`
	Certificate        []byte         `json:"certificate"`
	PrivateKey         []byte         `json:"private_key"`
	BootstrapHash      string         `json:"bootstrap_hash,omitempty"`
	BootstrapExpiresAt int64          `json:"bootstrap_expires_at"`
	RecoveryHash       string         `json:"recovery_hash"`
	Generation         uint64         `json:"generation"`
	Devices            []deviceRecord `json:"devices"`
	Pending            *pendingRecord `json:"pending,omitempty"`
}

// Invitation is transferred out of band during the one-time Mac installation.
// The certificate pin and random module ID survive phone credential changes.
type Invitation struct {
	Version           int    `json:"version"`
	Purpose           string `json:"purpose"`
	ModuleID          string `json:"module_id"`
	Host              string `json:"host"`
	Port              int    `json:"port"`
	CertificateSHA256 string `json:"certificate_sha256"`
	Secret            string `json:"secret"`
	ExpiresAt         int64  `json:"expires_at,omitempty"`
}

type Status struct {
	Version         int      `json:"version"`
	ModuleID        string   `json:"module_id"`
	Generation      uint64   `json:"generation"`
	CurrentDeviceID string   `json:"current_device_id"`
	Devices         []Device `json:"devices"`
}

type PrepareRequest struct {
	Kind              string `json:"kind"`       // bootstrap, recovery, or add-device
	Credential        string `json:"credential"` // generated and saved by the new phone
	Name              string `json:"name"`
	NewRecoverySecret string `json:"new_recovery_secret,omitempty"`
}

type Prepared struct {
	ModuleID  string `json:"module_id"`
	DeviceID  string `json:"device_id"`
	ExpiresAt int64  `json:"expires_at"`
}

// Store holds an exclusive process lock; all changes use a synced atomic rename.
// Each operation rereads disk, so an ambiguous fsync failure cannot leave an old
// in-memory registry granting access that has already been revoked on disk.
type Store struct {
	mu   sync.Mutex
	path string
	lock *os.File
}

func Open(path string) (*Store, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, ErrStorage
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, ErrStorage
	}
	fd, err := unix.Open(path+".lock", unix.O_CREAT|unix.O_RDWR|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if err != nil {
		return nil, ErrStorage
	}
	lock := os.NewFile(uintptr(fd), path+".lock")
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		lock.Close()
		return nil, ErrStorage
	}
	return &Store{path: path, lock: lock}, nil
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lock == nil {
		return nil
	}
	err := s.lock.Close()
	s.lock = nil
	return err
}

// Initialize refuses existing state, including corrupt state. It never replaces
// an installed identity or silently imports the Mac's shared development key.
func (s *Store) Initialize(now time.Time) (Invitation, Invitation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lock == nil {
		return Invitation{}, Invitation{}, ErrStorage
	}
	if _, err := os.Lstat(s.path); !errors.Is(err, os.ErrNotExist) {
		return Invitation{}, Invitation{}, ErrConflict
	}
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return Invitation{}, Invitation{}, err
	}
	moduleID := hex.EncodeToString(id[:])
	certificate, privateKey, err := newIdentity(moduleID)
	if err != nil {
		return Invitation{}, Invitation{}, err
	}
	bootstrap, err := NewSecret()
	if err != nil {
		return Invitation{}, Invitation{}, err
	}
	recovery, err := NewSecret()
	if err != nil {
		return Invitation{}, Invitation{}, err
	}
	bootstrapHash, _ := secretHash(bootstrap)
	recoveryHash, _ := secretHash(recovery)
	state := diskState{Version: Version, ModuleID: moduleID, Certificate: certificate,
		PrivateKey: privateKey, BootstrapHash: bootstrapHash, RecoveryHash: recoveryHash,
		BootstrapExpiresAt: now.Add(BootstrapLifetime).Unix(), Generation: 1, Devices: []deviceRecord{}}
	if err := s.write(state); err != nil {
		return Invitation{}, Invitation{}, err
	}
	pin := sha256.Sum256(certificate)
	invite := Invitation{Version: Version, Purpose: "module-bootstrap", ModuleID: moduleID,
		Host: Host, Port: Port, CertificateSHA256: hex.EncodeToString(pin[:]), Secret: bootstrap,
		ExpiresAt: state.BootstrapExpiresAt}
	backup := invite
	backup.Purpose, backup.Secret, backup.ExpiresAt = "module-recovery", recovery, 0
	return invite, backup, nil
}

func (s *Store) Status(credential string) (Status, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.read()
	if err != nil {
		return Status{}, err
	}
	device, ok := authorized(state, credential)
	if !ok {
		return Status{}, ErrUnauthorized
	}
	return status(state, device.ID), nil
}

func authorized(state diskState, credential string) (deviceRecord, bool) {
	for _, device := range state.Devices {
		if matches(credential, device.Hash) {
			return device, true
		}
	}
	return deviceRecord{}, false
}

func status(state diskState, current string) Status {
	result := Status{Version: Version, ModuleID: state.ModuleID, Generation: state.Generation,
		CurrentDeviceID: current, Devices: []Device{}}
	for _, device := range state.Devices {
		result.Devices = append(result.Devices, device.Device)
	}
	return result
}

// Prepare does not revoke anything. A recovery requires the replacement recovery
// secret up front: the phone must save both secrets before asking to commit.
func (s *Store) Prepare(authority string, request PrepareRequest, now time.Time) (Prepared, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.read()
	if err != nil {
		return Prepared{}, err
	}
	hash, err := secretHash(request.Credential)
	if err != nil || !validName(request.Name) {
		return Prepared{}, ErrInvalid
	}
	authorityHash, err := secretHash(authority)
	if err != nil || hash == authorityHash || hash == state.RecoveryHash || hash == state.BootstrapHash {
		return Prepared{}, ErrUnauthorized
	}
	var recoveryHash string
	switch request.Kind {
	case "bootstrap":
		if len(state.Devices) != 0 || now.Unix() >= state.BootstrapExpiresAt ||
			now.Unix() < state.BootstrapExpiresAt-int64((BootstrapLifetime+5*time.Minute)/time.Second) ||
			!matches(authority, state.BootstrapHash) {
			return Prepared{}, ErrUnauthorized
		}
	case "recovery":
		if !matches(authority, state.RecoveryHash) {
			return Prepared{}, ErrUnauthorized
		}
		recoveryHash, err = secretHash(request.NewRecoverySecret)
		if err != nil || recoveryHash == hash || recoveryHash == authorityHash || recoveryHash == state.BootstrapHash {
			return Prepared{}, ErrInvalid
		}
		for _, device := range state.Devices {
			if recoveryHash == device.Hash {
				return Prepared{}, ErrInvalid
			}
		}
	case "add-device":
		if _, ok := authorized(state, authority); !ok {
			return Prepared{}, ErrUnauthorized
		}
	default:
		return Prepared{}, ErrInvalid
	}
	if request.Kind != "recovery" && request.NewRecoverySecret != "" {
		return Prepared{}, ErrInvalid
	}
	for _, device := range state.Devices {
		if device.Hash == hash {
			return Prepared{}, ErrConflict
		}
	}
	if state.Pending != nil && state.Pending.ExpiresAt > now.Unix() {
		pending := state.Pending
		if pending.Device.Hash == hash && pending.Kind == request.Kind && pending.AuthorityHash == authorityHash && pending.RecoveryHash == recoveryHash && pending.Device.Name == request.Name {
			return Prepared{state.ModuleID, pending.Device.ID, pending.ExpiresAt}, nil
		}
		// An existing phone cannot block the offline recovery authority by
		// repeatedly starting another phone enrollment.
		if request.Kind != "recovery" || pending.Kind == "recovery" {
			return Prepared{}, ErrConflict
		}
	}
	if request.Kind != "recovery" && len(state.Devices) >= MaxDevices {
		return Prepared{}, ErrCapacity
	}
	id, err := NewSecret()
	if err != nil {
		return Prepared{}, err
	}
	state.Pending = &pendingRecord{Kind: request.Kind, AuthorityHash: authorityHash, RecoveryHash: recoveryHash,
		Device:    deviceRecord{Device: Device{ID: id, Name: request.Name, CreatedAt: now.Unix()}, Hash: hash},
		ExpiresAt: now.Add(PendingLifetime).Unix()}
	if err := s.write(state); err != nil {
		return Prepared{}, err
	}
	return Prepared{state.ModuleID, id, state.Pending.ExpiresAt}, nil
}

func (s *Store) Commit(credential string, now time.Time) (Status, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.read()
	if err != nil {
		return Status{}, err
	}
	// Retrying after a lost response is safe, even after reboot.
	if device, ok := authorized(state, credential); ok {
		return status(state, device.ID), nil
	}
	pending := state.Pending
	if pending == nil || pending.ExpiresAt <= now.Unix() ||
		now.Unix() < pending.Device.CreatedAt-300 || !matches(credential, pending.Device.Hash) {
		return Status{}, ErrUnauthorized
	}
	if pending.Kind == "recovery" {
		state.Devices = nil
		state.RecoveryHash = pending.RecoveryHash
	}
	state.Devices = append(state.Devices, pending.Device)
	state.BootstrapHash = ""
	state.BootstrapExpiresAt = 0
	state.Pending = nil
	state.Generation++
	if err := s.write(state); err != nil {
		return Status{}, err
	}
	return status(state, pending.Device.ID), nil
}

func (s *Store) Revoke(credential, deviceID string) (Status, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.read()
	if err != nil {
		return Status{}, err
	}
	actor, ok := authorized(state, credential)
	if !ok {
		return Status{}, ErrUnauthorized
	}
	if deviceID == "" {
		return Status{}, ErrInvalid
	}
	for index, device := range state.Devices {
		if device.ID != deviceID {
			continue
		}
		state.Devices = append(state.Devices[:index], state.Devices[index+1:]...)
		// A revoked owner cannot leave behind an enrollment it authorized.
		if state.Pending != nil && state.Pending.AuthorityHash == device.Hash {
			state.Pending = nil
		}
		state.Generation++
		if err := s.write(state); err != nil {
			return Status{}, err
		}
		break
	}
	return status(state, actor.ID), nil
}

// Cancel is idempotent after a lost response. It never undoes a committed
// authorization: the phone must retry commit and retain its active credential.
func (s *Store) Cancel(credential string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.read()
	if err != nil {
		return err
	}
	if _, err := secretHash(credential); err != nil {
		return ErrUnauthorized
	}
	if _, ok := authorized(state, credential); ok {
		return ErrConflict
	}
	if state.Pending == nil {
		return nil
	}
	if !matches(credential, state.Pending.Device.Hash) {
		return ErrUnauthorized
	}
	state.Pending = nil
	return s.write(state)
}

func validName(name string) bool {
	if len(name) == 0 || len(name) > 80 || !utf8.ValidString(name) {
		return false
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func (s *Store) read() (diskState, error) {
	var state diskState
	if s.lock == nil {
		return state, ErrStorage
	}
	fd, err := unix.Open(s.path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return state, ErrStorage
	}
	file := os.NewFile(uintptr(fd), s.path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 64<<10 {
		return state, ErrStorage
	}
	decoder := json.NewDecoder(io.LimitReader(file, 64<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&state) != nil {
		return state, ErrStorage
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF || !validState(state) {
		return diskState{}, ErrStorage
	}
	return state, nil
}

func validState(state diskState) bool {
	validHex := func(s string, size int) bool {
		b, err := hex.DecodeString(s)
		return err == nil && len(b) == size && hex.EncodeToString(b) == s
	}
	if state.Version != Version || !validHex(state.ModuleID, 16) || !validHex(state.RecoveryHash, 32) || state.Generation == 0 || len(state.Devices) > MaxDevices {
		return false
	}
	if state.BootstrapHash != "" && (!validHex(state.BootstrapHash, 32) || len(state.Devices) != 0 || state.BootstrapExpiresAt <= 0) {
		return false
	}
	seen := map[string]bool{state.RecoveryHash: true}
	ids := map[string]bool{}
	for _, device := range state.Devices {
		_, idError := secretHash(device.ID)
		if !validHex(device.Hash, 32) || seen[device.Hash] || ids[device.ID] || idError != nil || !validName(device.Name) || device.CreatedAt <= 0 {
			return false
		}
		seen[device.Hash], ids[device.ID] = true, true
	}
	if p := state.Pending; p != nil {
		_, idError := secretHash(p.Device.ID)
		if !validHex(p.Device.Hash, 32) || seen[p.Device.Hash] || idError != nil || ids[p.Device.ID] || !validName(p.Device.Name) || p.Device.CreatedAt <= 0 || p.ExpiresAt <= p.Device.CreatedAt || p.ExpiresAt-p.Device.CreatedAt > int64(PendingLifetime/time.Second) {
			return false
		}
		switch p.Kind {
		case "bootstrap":
			if p.AuthorityHash != state.BootstrapHash || p.AuthorityHash == "" || p.RecoveryHash != "" {
				return false
			}
		case "recovery":
			if p.AuthorityHash != state.RecoveryHash || !validHex(p.RecoveryHash, 32) || seen[p.RecoveryHash] || p.RecoveryHash == p.Device.Hash {
				return false
			}
		case "add-device":
			found := false
			for _, device := range state.Devices {
				found = found || device.Hash == p.AuthorityHash
			}
			if !found || p.RecoveryHash != "" || len(state.Devices) >= MaxDevices {
				return false
			}
		default:
			return false
		}
	}
	return len(state.Certificate) != 0 && len(state.PrivateKey) != 0
}

func (s *Store) write(state diskState) error {
	if !validState(state) {
		return ErrStorage
	}
	data, err := json.Marshal(state)
	if err != nil {
		return ErrStorage
	}
	file, err := os.CreateTemp(filepath.Dir(s.path), ".pairing-*")
	if err != nil {
		return ErrStorage
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		return ErrStorage
	}
	if os.Rename(file.Name(), s.path) != nil {
		return ErrStorage
	}
	dir, err := os.Open(filepath.Dir(s.path))
	if err != nil {
		return ErrStorage
	}
	defer dir.Close()
	if dir.Sync() != nil {
		return ErrStorage
	}
	return nil
}
