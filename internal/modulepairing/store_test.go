package modulepairing

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func secret(t *testing.T) string {
	t.Helper()
	s, err := NewSecret()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func fixture(t *testing.T) (*Store, Invitation, Invitation, time.Time) {
	t.Helper()
	store, err := Open(filepath.Join(t.TempDir(), "private", "registry.json"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	now := time.Now().Truncate(time.Second)
	invite, recovery, err := store.Initialize(now)
	if err != nil {
		t.Fatal(err)
	}
	return store, invite, recovery, now
}

func enroll(t *testing.T, store *Store, invite Invitation, now time.Time) (string, Status) {
	t.Helper()
	credential := secret(t)
	if _, err := store.Prepare(invite.Secret, PrepareRequest{Kind: "bootstrap", Credential: credential, Name: "我的 iPhone"}, now); err != nil {
		t.Fatal(err)
	}
	status, err := store.Commit(credential, now)
	if err != nil {
		t.Fatal(err)
	}
	return credential, status
}

func TestIdentityAndLongTermAuthorization(t *testing.T) {
	store, invite, recovery, now := fixture(t)
	other, otherInvite, _, _ := fixture(t)
	if invite.ModuleID == otherInvite.ModuleID || invite.CertificateSHA256 == otherInvite.CertificateSHA256 {
		t.Fatal("module identity reused")
	}
	_ = other
	credential, original := enroll(t, store, invite, now)
	if _, err := store.Prepare(invite.Secret, PrepareRequest{Kind: "bootstrap", Credential: secret(t), Name: "replay"}, now); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("bootstrap reused", err)
	}
	if _, _, err := store.Initialize(now); !errors.Is(err, ErrConflict) {
		t.Fatal("existing identity replaced", err)
	}
	path := store.path
	store.Close()
	reopened, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	// No clock/expiry parameter is used for an already authorized phone.
	status, err := reopened.Commit(credential, now.AddDate(20, 0, 0))
	if err != nil || status.ModuleID != original.ModuleID || status.Generation != original.Generation {
		t.Fatal("long-term authorization changed", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{credential, invite.Secret, recovery.Secret} {
		if bytes.Contains(data, []byte(private)) {
			t.Fatal("raw capability stored on module")
		}
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("registry is not private")
	}
}

func TestRecoveryCommitsAtomicallyAndRetriesAfterRestart(t *testing.T) {
	store, invite, recovery, now := fixture(t)
	oldCredential, before := enroll(t, store, invite, now)
	next, nextRecovery := secret(t), secret(t)
	request := PrepareRequest{Kind: "recovery", Credential: next, Name: "新 iPhone", NewRecoverySecret: nextRecovery}
	prepared, err := store.Prepare(recovery.Secret, request, now)
	if err != nil {
		t.Fatal(err)
	}
	if retried, err := store.Prepare(recovery.Secret, request, now.Add(time.Second)); err != nil || retried != prepared {
		t.Fatal("prepare retry changed transaction", err)
	}
	if _, err := store.Status(next); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("pending phone already authorized")
	}
	if _, err := store.Status(oldCredential); err != nil {
		t.Fatal("old phone revoked before commit")
	}
	path := store.path
	store.Close()
	store, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	after, err := store.Commit(next, now.Add(2*time.Second))
	if err != nil || after.ModuleID != before.ModuleID || len(after.Devices) != 1 || after.Generation != before.Generation+1 {
		t.Fatal("recovery failed", err)
	}
	if _, err := store.Status(oldCredential); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("old phone still authorized")
	}
	if _, err := store.Prepare(recovery.Secret, request, now); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("old recovery code still usable")
	}
	if retried, err := store.Commit(next, now.Add(time.Minute)); err != nil || retried.Generation != after.Generation {
		t.Fatal("commit not idempotent")
	}
	if _, err := store.Prepare(nextRecovery, PrepareRequest{Kind: "recovery", Credential: secret(t), Name: "another", NewRecoverySecret: secret(t)}, now); err != nil {
		t.Fatal("new recovery code unusable", err)
	}
}

func TestExpiryDoesNotRevokeOwner(t *testing.T) {
	store, invite, recovery, now := fixture(t)
	if _, err := store.Prepare(invite.Secret, PrepareRequest{Kind: "bootstrap", Credential: secret(t), Name: "expired"}, now.Add(BootstrapLifetime)); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("expired invite accepted")
	}
	owner, _ := enroll(t, store, invite, now)
	next := secret(t)
	if _, err := store.Prepare(recovery.Secret, PrepareRequest{Kind: "recovery", Credential: next, Name: "next", NewRecoverySecret: secret(t)}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Commit(next, now.Add(PendingLifetime)); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("expired preparation accepted")
	}
	if _, err := store.Status(owner); err != nil {
		t.Fatal("expiry revoked owner")
	}
}

func TestRevocationCancelsDelegatedEnrollment(t *testing.T) {
	store, invite, _, now := fixture(t)
	first, firstStatus := enroll(t, store, invite, now)
	second := secret(t)
	if _, err := store.Prepare(first, PrepareRequest{Kind: "add-device", Credential: second, Name: "second"}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Commit(second, now); err != nil {
		t.Fatal(err)
	}
	third := secret(t)
	if _, err := store.Prepare(first, PrepareRequest{Kind: "add-device", Credential: third, Name: "third"}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Revoke(second, firstStatus.CurrentDeviceID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Commit(third, now); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("revoked owner left enrollment")
	}
	if _, err := store.Status(first); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("revocation ineffective")
	}
	if _, err := store.Revoke(second, firstStatus.CurrentDeviceID); err != nil {
		t.Fatal("revocation retry failed")
	}
}

func TestStorageFailsClosed(t *testing.T) {
	store, invite, _, now := fixture(t)
	credential, _ := enroll(t, store, invite, now)
	if second, err := Open(store.path); err == nil {
		second.Close()
		t.Fatal("concurrent process accepted")
	}
	if err := os.Chmod(store.path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Status(credential); !errors.Is(err, ErrStorage) {
		t.Fatal("public registry accepted")
	}
	if err := os.Chmod(store.path, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(store.path, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Status(credential); !errors.Is(err, ErrStorage) {
		t.Fatal("corrupt registry accepted")
	}
	if _, _, err := store.Initialize(now); !errors.Is(err, ErrConflict) {
		t.Fatal("corrupt registry overwritten")
	}
}

func TestCancelRetryCannotDiscardCommittedCredential(t *testing.T) {
	store, invite, _, now := fixture(t)
	candidate := secret(t)
	request := PrepareRequest{Kind: "bootstrap", Credential: candidate, Name: "phone"}
	if _, err := store.Prepare(invite.Secret, request, now); err != nil {
		t.Fatal(err)
	}
	if err := store.Cancel(candidate); err != nil {
		t.Fatal(err)
	}
	if err := store.Cancel(candidate); err != nil {
		t.Fatal("cancel retry failed", err)
	}
	if _, err := store.Commit(candidate, now); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("cancelled credential activated")
	}
	if _, err := store.Prepare(invite.Secret, request, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Commit(candidate, now); err != nil {
		t.Fatal(err)
	}
	if err := store.Cancel(candidate); !errors.Is(err, ErrConflict) {
		t.Fatal("cancel discarded committed credential")
	}
}

func TestRecoveryOverridesPhoneEnrollmentAndResetsCapacity(t *testing.T) {
	store, invite, recovery, now := fixture(t)
	owner, _ := enroll(t, store, invite, now)
	for i := 1; i < MaxDevices; i++ {
		candidate := secret(t)
		if _, err := store.Prepare(owner, PrepareRequest{Kind: "add-device", Credential: candidate, Name: "phone"}, now); err != nil {
			t.Fatal(err)
		}
		if _, err := store.Commit(candidate, now); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.Prepare(owner, PrepareRequest{Kind: "add-device", Credential: secret(t), Name: "too many"}, now); !errors.Is(err, ErrCapacity) {
		t.Fatal("device bound not enforced")
	}
	recovered, replacementBackup := secret(t), secret(t)
	if _, err := store.Prepare(recovery.Secret, PrepareRequest{Kind: "recovery", Credential: recovered, Name: "recovered", NewRecoverySecret: replacementBackup}, now); err != nil {
		t.Fatal(err)
	}
	status, err := store.Commit(recovered, now)
	if err != nil || len(status.Devices) != 1 {
		t.Fatal("recovery failed at capacity")
	}
	other := secret(t)
	if _, err := store.Prepare(recovered, PrepareRequest{Kind: "add-device", Credential: other, Name: "pending"}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Prepare(replacementBackup, PrepareRequest{Kind: "recovery", Credential: secret(t), Name: "restore", NewRecoverySecret: secret(t)}, now); err != nil {
		t.Fatal("owner enrollment blocked recovery", err)
	}
}

func TestRejectsClockRollbackAndNoncanonicalCapabilities(t *testing.T) {
	store, invite, _, now := fixture(t)
	request := PrepareRequest{Kind: "bootstrap", Credential: secret(t), Name: "phone"}
	if _, err := store.Prepare(invite.Secret, request, now.Add(-time.Hour)); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("clock rollback extended bootstrap")
	}
	if _, err := store.Prepare(invite.Secret+"\n", request, now); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("noncanonical capability accepted")
	}
	if _, err := store.Prepare(invite.Secret, request, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Commit(request.Credential, now.Add(-time.Hour)); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("clock rollback extended pending authorization")
	}
}

func TestParallelPrepareHasOneWinner(t *testing.T) {
	store, invite, _, now := fixture(t)
	owner, _ := enroll(t, store, invite, now)
	credentials := []string{secret(t), secret(t), secret(t)}
	results := make(chan error, len(credentials))
	var wg sync.WaitGroup
	for _, candidate := range credentials {
		wg.Go(func() {
			_, err := store.Prepare(owner, PrepareRequest{Kind: "add-device", Credential: candidate, Name: "candidate"}, now)
			results <- err
		})
	}
	wg.Wait()
	close(results)
	winners := 0
	for err := range results {
		if err == nil {
			winners++
		} else if !errors.Is(err, ErrConflict) {
			t.Fatal(err)
		}
	}
	if winners != 1 {
		t.Fatal("multiple pending transactions")
	}
}

func TestHTTPSAndCertificatePin(t *testing.T) {
	store, invite, _, now := fixture(t)
	owner, _ := enroll(t, store, invite, now)
	config, err := store.TLSConfig()
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(Server{Store: store})
	server.TLS = config
	server.StartTLS()
	defer server.Close()
	clientConfig := &tls.Config{MinVersion: tls.VersionTLS13,
		// Replace public CA verification with an exact out-of-band identity pin.
		InsecureSkipVerify: true, VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) != 1 {
				return ErrUnauthorized
			}
			hash := sha256.Sum256(state.PeerCertificates[0].Raw)
			if hex.EncodeToString(hash[:]) != invite.CertificateSHA256 {
				return ErrUnauthorized
			}
			return nil
		}}
	transport := &http.Transport{TLSClientConfig: clientConfig}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/status", strings.NewReader("{}"))
	request.Header.Set("Authorization", "Bearer "+owner)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	data, _ := io.ReadAll(response.Body)
	if response.StatusCode != 200 || !bytes.Contains(data, []byte(invite.ModuleID)) || bytes.Contains(data, []byte(owner)) {
		t.Fatal("invalid secure status response")
	}
	clientConfig = clientConfig.Clone()
	clientConfig.VerifyConnection = func(tls.ConnectionState) error { return ErrUnauthorized }
	badTransport := &http.Transport{TLSClientConfig: clientConfig}
	defer badTransport.CloseIdleConnections()
	badClient := &http.Client{Transport: badTransport, Timeout: 3 * time.Second}
	request, _ = http.NewRequest(http.MethodPost, server.URL+"/v1/status", strings.NewReader("{}"))
	request.Header.Set("Authorization", "Bearer "+owner)
	if response, err := badClient.Do(request); err == nil {
		response.Body.Close()
		t.Fatal("wrong pin accepted")
	}
}

func TestHTTPRejectsCleartextMalformedAndLeakedTokens(t *testing.T) {
	store, invite, _, now := fixture(t)
	owner, _ := enroll(t, store, invite, now)
	for _, test := range []struct {
		name, auth, body string
		tls              bool
		code             int
	}{
		{"cleartext", "Bearer " + owner, "{}", false, 400},
		{"no bearer", owner, "{}", true, 401},
		{"wrong credential", "Bearer " + secret(t), "{}", true, 401},
		{"unknown field", "Bearer " + owner, `{"secret":"no"}`, true, 400},
		{"trailing", "Bearer " + owner, "{}{}", true, 400},
		{"oversize", "Bearer " + owner, strings.Repeat(" ", 4097) + "{}", true, 400},
	} {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest("POST", "/v1/status", strings.NewReader(test.body))
			if test.tls {
				request.TLS = &tls.ConnectionState{Version: tls.VersionTLS13}
			}
			request.Header.Set("Authorization", test.auth)
			response := httptest.NewRecorder()
			(Server{Store: store}).ServeHTTP(response, request)
			if response.Code != test.code || strings.Contains(response.Body.String(), owner) {
				t.Fatal("unexpected error response", response.Code)
			}
			var value map[string]any
			if json.Unmarshal(response.Body.Bytes(), &value) != nil {
				t.Fatal("invalid error JSON")
			}
		})
	}
}

func TestHTTPSIssuesSessionOnlyToAuthorizedPhone(t *testing.T) {
	store, invite, _, now := fixture(t)
	owner, _ := enroll(t, store, invite, now)
	path := filepath.Join(t.TempDir(), "voice-sessions.v1")
	server := Server{Store: store, Sessions: &SessionRegistry{Path: path}}
	for _, test := range []struct {
		credential string
		code       int
	}{
		{secret(t), http.StatusUnauthorized}, {owner, http.StatusOK},
	} {
		request := httptest.NewRequest(http.MethodPost, "/v1/session", strings.NewReader("{}"))
		request.TLS = &tls.ConnectionState{Version: tls.VersionTLS13}
		request.Header.Set("Authorization", "Bearer "+test.credential)
		response := httptest.NewRecorder()
		server.ServeHTTP(response, request)
		if response.Code != test.code {
			t.Fatalf("got %d want %d", response.Code, test.code)
		}
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("session was not securely persisted")
	}
}
