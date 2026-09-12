package modulepairing

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The certificate is a pinned device identity, not a public-CA certificate.
// Its validity does not impose a periodic Mac re-enrollment requirement. TLS
// still proves possession of its private key and negotiates fresh session keys.
func newIdentity(moduleID string) ([]byte, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, err
	}
	template := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: moduleID},
		NotBefore: time.Unix(0, 0), NotAfter: time.Date(9999, 12, 31, 0, 0, 0, 0, time.UTC),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses: []net.IP{net.ParseIP(Host)}, BasicConstraintsValid: true,
	}
	certificate, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	return certificate, private, err
}

func (s *Store) TLSConfig() (*tls.Config, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.read()
	if err != nil {
		return nil, err
	}
	key, err := x509.ParsePKCS8PrivateKey(state.PrivateKey)
	if err != nil {
		return nil, ErrStorage
	}
	private, ok := key.(*ecdsa.PrivateKey)
	if !ok {
		return nil, ErrStorage
	}
	certificate, err := x509.ParseCertificate(state.Certificate)
	if err != nil || certificate.Subject.CommonName != state.ModuleID {
		return nil, ErrStorage
	}
	public, ok := certificate.PublicKey.(*ecdsa.PublicKey)
	if !ok || !private.PublicKey.Equal(public) {
		return nil, ErrStorage
	}
	return &tls.Config{MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		// Avoid the hybrid KEM scratch allocation on the 43 MiB module.
		CurvePreferences:       []tls.CurveID{tls.X25519, tls.CurveP256},
		SessionTicketsDisabled: true,
		Certificates:           []tls.Certificate{{Certificate: [][]byte{state.Certificate}, PrivateKey: private}},
	}, nil
}

type Server struct{ Store *Store }

// Serve accepts a prebound USB listener so deployment cannot accidentally use
// a wildcard address. Tests use the handler separately with an ephemeral port.
func (s Server) Serve(ctx context.Context, listener net.Listener) error {
	defer listener.Close()
	address, ok := listener.Addr().(*net.TCPAddr)
	if !ok || !address.IP.Equal(net.ParseIP(Host)) || address.Port != Port {
		return ErrInvalid
	}
	config, err := s.Store.TLSConfig()
	if err != nil {
		return err
	}
	server := &http.Server{Handler: s, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 8 * time.Second,
		WriteTimeout: 8 * time.Second, IdleTimeout: 5 * time.Second, MaxHeaderBytes: 4096,
		TLSNextProto: map[string]func(*http.Server, *tls.Conn, http.Handler){},
	}
	// One bounded management connection at a time. No periodic network calls,
	// cloud dependency, or per-phone goroutines survive a request.
	bounded := &usbListener{Listener: listener, slots: make(chan struct{}, 1)}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = server.Close()
		case <-done:
		}
	}()
	err = server.Serve(tls.NewListener(bounded, config))
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

type usbListener struct {
	net.Listener
	slots chan struct{}
}
type limitedConnection struct {
	net.Conn
	release func()
}

func (c *limitedConnection) Close() error { err := c.Conn.Close(); c.release(); return err }

func onceRelease(slots chan struct{}) func() {
	var once sync.Once
	return func() { once.Do(func() { <-slots }) }
}

func (l *usbListener) Accept() (net.Conn, error) {
	for {
		connection, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		remote, ok := connection.RemoteAddr().(*net.TCPAddr)
		ip := net.IP(nil)
		if ok {
			ip = remote.IP.To4()
		}
		if ip == nil || ip[0] != 192 || ip[1] != 168 || ip[2] != 225 {
			connection.Close()
			continue
		}
		select {
		case l.slots <- struct{}{}:
			return &limitedConnection{Conn: connection, release: onceRelease(l.slots)}, nil
		default:
			connection.Close()
		}
	}
}

func (s Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Connection", "close")
	if r.TLS == nil || r.TLS.Version != tls.VersionTLS13 || r.Method != http.MethodPost || r.URL.RawQuery != "" {
		writeError(w, ErrInvalid)
		return
	}
	// HTTP headers are never logged. Unknown fields and trailing JSON fail closed.
	if len(r.Header.Values("Authorization")) != 1 || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		writeError(w, ErrUnauthorized)
		return
	}
	authority := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if _, err := secretHash(authority); err != nil {
		writeError(w, ErrUnauthorized)
		return
	}
	decode := func(value any) error {
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		decoder.DisallowUnknownFields()
		if decoder.Decode(value) != nil {
			return ErrInvalid
		}
		var extra any
		if decoder.Decode(&extra) != io.EOF {
			return ErrInvalid
		}
		return nil
	}
	var result any
	var err error
	switch r.URL.Path {
	case "/v1/prepare":
		var request PrepareRequest
		if err = decode(&request); err == nil {
			result, err = s.Store.Prepare(authority, request, time.Now())
		}
	case "/v1/commit", "/v1/status":
		var empty struct{}
		if err = decode(&empty); err == nil {
			if r.URL.Path == "/v1/commit" {
				result, err = s.Store.Commit(authority, time.Now())
			} else {
				result, err = s.Store.Status(authority)
			}
		}
	case "/v1/revoke":
		var request struct {
			DeviceID string `json:"device_id"`
		}
		if err = decode(&request); err == nil {
			result, err = s.Store.Revoke(authority, request.DeviceID)
		}
	case "/v1/cancel":
		var empty struct{}
		if err = decode(&empty); err == nil {
			err = s.Store.Cancel(authority)
			result = empty
		}
	default:
		err = ErrInvalid
	}
	if err != nil {
		writeError(w, err)
		return
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		writeError(w, ErrStorage)
		return
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(encoded)))
	_, _ = w.Write(encoded)
}

func writeError(w http.ResponseWriter, err error) {
	code, message := http.StatusInternalServerError, "storage_unavailable"
	switch {
	case errors.Is(err, ErrUnauthorized):
		code, message = http.StatusUnauthorized, "unauthorized"
	case errors.Is(err, ErrInvalid):
		code, message = http.StatusBadRequest, "invalid_request"
	case errors.Is(err, ErrConflict):
		code, message = http.StatusConflict, "change_pending"
	case errors.Is(err, ErrCapacity):
		code, message = http.StatusConflict, "device_limit"
	}
	encoded, _ := json.Marshal(struct {
		Error string `json:"error"`
	}{message})
	w.Header().Set("Content-Length", strconv.Itoa(len(encoded)))
	w.WriteHeader(code)
	_, _ = w.Write(encoded)
}
