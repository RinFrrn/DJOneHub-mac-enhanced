package modulepush

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

const (
	ControlVersion            = 1
	ControlHeaderBytes        = 20
	ControlNonceBytes         = 32
	ControlTagBytes           = 32
	ControlMaxRequestPayload  = 64 << 10
	ControlMaxResponsePayload = 8 << 10
	controlMagic              = 0x444A4F4E // DJON
	controlHello              = 1
	controlRequest            = 2
	controlResponse           = 3
)

type ControlOperation uint8

const (
	ControlStatusOperation ControlOperation = iota + 1
	ControlSettingsOperation
	ControlWebPushOperation
	ControlCertificateOperation
	ControlTestBarkOperation
	ControlTestWebPushOperation
)

type ControlStatusCode uint8

const (
	ControlOK ControlStatusCode = iota
	ControlMalformed
	ControlAuthenticationFailed
	ControlInvalidConfiguration
	ControlPushFailed
	ControlInternal
)

type ControlSettings struct {
	BarkURL        *string `json:"bark_url,omitempty"`
	ClearBark      bool    `json:"clear_bark,omitempty"`
	BarkCallSound  bool    `json:"bark_call_sound"`
	ShowCallNumber bool    `json:"show_call_number"`
	ShowSMSBody    bool    `json:"show_sms_body"`
}

type ControlStatus struct {
	Version           int    `json:"version"`
	BarkConfigured    bool   `json:"bark_configured"`
	BarkHost          string `json:"bark_host,omitempty"`
	BarkCallSound     bool   `json:"bark_call_sound"`
	ShowCallNumber    bool   `json:"show_call_number"`
	ShowSMSBody       bool   `json:"show_sms_body"`
	WebPushConfigured bool   `json:"web_push_configured"`
	WebPushPublicKey  string `json:"web_push_public_key"`
	CustomCA          bool   `json:"custom_ca"`
	CustomCAHash      string `json:"custom_ca_hash,omitempty"`
}

type WebPushExport struct {
	Version      int                  `json:"version"`
	PublicKey    string               `json:"public_key"`
	Subscription webpush.Subscription `json:"subscription"`
}

type ControlServer struct {
	Address      string
	PairingKey   string
	ConfigPath   string
	CustomCAPath string
	Sender       *Sender
	performMu    sync.Mutex
}

func (s *ControlServer) Serve(ctx context.Context) error {
	listener, err := net.Listen("tcp4", s.Address)
	if err != nil {
		return errors.New("cannot listen for notification configuration")
	}
	defer listener.Close()
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	semaphore := make(chan struct{}, 2)
	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			if ctx.Err() != nil {
				return nil
			}
			return errors.New("notification configuration listener failed")
		}
		if !sameUSBSubnet(connection.LocalAddr(), connection.RemoteAddr()) {
			_ = connection.Close()
			continue
		}
		select {
		case semaphore <- struct{}{}:
			go func() {
				defer func() { <-semaphore }()
				s.handle(connection)
			}()
		default:
			_ = connection.Close()
		}
	}
}

func sameUSBSubnet(local, remote net.Addr) bool {
	l, lok := local.(*net.TCPAddr)
	r, rok := remote.(*net.TCPAddr)
	if !lok || !rok || l.IP.To4() == nil || r.IP.To4() == nil {
		return false
	}
	return l.IP.To4()[0] == r.IP.To4()[0] && l.IP.To4()[1] == r.IP.To4()[1] && l.IP.To4()[2] == r.IP.To4()[2]
}

func (s *ControlServer) handle(connection net.Conn) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(8 * time.Second))
	key, err := readPairingKey(s.PairingKey)
	if err != nil {
		return
	}
	defer clear(key)
	nonce := make([]byte, ControlNonceBytes)
	if _, err = io.ReadFull(rand.Reader, nonce); err != nil {
		return
	}
	if err = writeControlFrame(connection, encodeControlHello(nonce)); err != nil {
		return
	}
	header := make([]byte, ControlHeaderBytes)
	if _, err = io.ReadFull(connection, header); err != nil {
		return
	}
	operation, requestID, size, ok := decodeControlHeader(header, controlRequest)
	if !ok || size > ControlMaxRequestPayload {
		return
	}
	tail := make([]byte, size+ControlTagBytes)
	if _, err = io.ReadFull(connection, tail); err != nil {
		return
	}
	unsigned := append(append([]byte{}, header...), tail[:size]...)
	expected := controlTag(key, nonce, unsigned)
	if !hmac.Equal(expected, tail[size:]) {
		response := encodeControlResponse(key, nonce, operation, requestID, ControlAuthenticationFailed, nil)
		_ = writeControlFrame(connection, response)
		return
	}
	status, payload := s.perform(operation, tail[:size])
	response := encodeControlResponse(key, nonce, operation, requestID, status, payload)
	_ = writeControlFrame(connection, response)
}

func writeControlFrame(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		count, err := writer.Write(data)
		if err != nil {
			return err
		}
		if count == 0 {
			return io.ErrShortWrite
		}
		data = data[count:]
	}
	return nil
}

func (s *ControlServer) perform(operation ControlOperation, payload []byte) (ControlStatusCode, []byte) {
	s.performMu.Lock()
	defer s.performMu.Unlock()
	switch operation {
	case ControlStatusOperation:
		if len(payload) != 0 {
			return ControlMalformed, nil
		}
		status := s.status()
		encoded, err := json.Marshal(status)
		if err != nil {
			return ControlInternal, nil
		}
		return ControlOK, encoded
	case ControlSettingsOperation:
		var settings ControlSettings
		if decodeStrict(payload, &settings) != nil {
			return ControlMalformed, nil
		}
		config := s.Sender.ConfigSnapshot()
		if settings.ClearBark {
			config.BarkURL = ""
		} else if settings.BarkURL != nil {
			config.BarkURL = strings.TrimRight(strings.TrimSpace(*settings.BarkURL), "/")
		}
		config.BarkCallSound = settings.BarkCallSound
		config.Privacy.ShowCallNumber = settings.ShowCallNumber
		config.Privacy.ShowSMSBody = settings.ShowSMSBody
		if err := config.Validate(); err != nil {
			return ControlInvalidConfiguration, nil
		}
		if err := WritePrivateJSON(s.ConfigPath, config); err != nil {
			return ControlInternal, nil
		}
		s.Sender.UpdateConfig(config)
		return ControlOK, nil
	case ControlWebPushOperation:
		var exported WebPushExport
		if decodeStrict(payload, &exported) != nil || exported.Version != 1 {
			return ControlMalformed, nil
		}
		config := s.Sender.ConfigSnapshot()
		if exported.PublicKey != config.WebPush.PublicKey {
			return ControlInvalidConfiguration, nil
		}
		config.WebPush.Subscription = &exported.Subscription
		if err := config.Validate(); err != nil {
			return ControlInvalidConfiguration, nil
		}
		if err := WritePrivateJSON(s.ConfigPath, config); err != nil {
			return ControlInternal, nil
		}
		s.Sender.UpdateConfig(config)
		return ControlOK, nil
	case ControlCertificateOperation:
		if len(payload) == 0 {
			if err := os.Remove(s.CustomCAPath); err != nil && !errors.Is(err, os.ErrNotExist) {
				return ControlInternal, nil
			}
			if err := s.Sender.ReloadCustomCA(s.CustomCAPath); err != nil {
				return ControlInternal, nil
			}
			return ControlOK, nil
		}
		normalized, err := normalizeCertificates(payload)
		if err != nil {
			return ControlInvalidConfiguration, nil
		}
		if err := WritePrivateFile(s.CustomCAPath, normalized); err != nil {
			return ControlInternal, nil
		}
		if err := s.Sender.ReloadCustomCA(s.CustomCAPath); err != nil {
			return ControlInternal, nil
		}
		return ControlOK, nil
	case ControlTestBarkOperation, ControlTestWebPushOperation:
		if len(payload) != 0 {
			return ControlMalformed, nil
		}
		transport := "bark"
		if operation == ControlTestWebPushOperation {
			transport = "webpush"
		}
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		result := s.Sender.Send(ctx, Delivery{ID: "test", Kind: "test", Transport: transport, Expires: time.Now().Add(12 * time.Second)})
		if result.Err != nil {
			return ControlPushFailed, nil
		}
		return ControlOK, nil
	default:
		return ControlMalformed, nil
	}
}

func (s *ControlServer) status() ControlStatus {
	config := s.Sender.ConfigSnapshot()
	status := ControlStatus{
		Version: 1, BarkConfigured: config.BarkURL != "", BarkCallSound: config.BarkCallSound,
		ShowCallNumber: config.Privacy.ShowCallNumber, ShowSMSBody: config.Privacy.ShowSMSBody,
		WebPushConfigured: config.WebPush.Subscription != nil, WebPushPublicKey: config.WebPush.PublicKey,
	}
	if endpoint, err := url.Parse(config.BarkURL); err == nil {
		status.BarkHost = endpoint.Hostname()
	}
	if data, err := os.ReadFile(s.CustomCAPath); err == nil {
		digest := sha256.Sum256(data)
		status.CustomCA, status.CustomCAHash = true, hex.EncodeToString(digest[:8])
	}
	return status
}

func decodeStrict(data []byte, value any) error {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return errors.New("trailing data")
	}
	return nil
}

func normalizeCertificates(data []byte) ([]byte, error) {
	if len(data) > ControlMaxRequestPayload || strings.Contains(string(data), "PRIVATE KEY") {
		return nil, errors.New("invalid certificate")
	}
	var certificates []*x509.Certificate
	rest := data
	for {
		block, remaining := pem.Decode(rest)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			return nil, errors.New("invalid PEM block")
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, err
		}
		certificates = append(certificates, certificate)
		rest = remaining
	}
	if len(certificates) == 0 {
		certificate, err := x509.ParseCertificate(data)
		if err != nil {
			return nil, errors.New("invalid certificate")
		}
		certificates = append(certificates, certificate)
	} else if strings.TrimSpace(string(rest)) != "" {
		return nil, errors.New("trailing certificate data")
	}
	var output []byte
	for _, certificate := range certificates {
		output = append(output, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Raw})...)
	}
	return output, nil
}

func readPairingKey(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 || info.Size() != 32 {
		return nil, errors.New("invalid pairing key")
	}
	key, err := os.ReadFile(path)
	if err != nil || len(key) != 32 {
		return nil, errors.New("invalid pairing key")
	}
	return key, nil
}

func encodeControlHello(nonce []byte) []byte {
	header := controlHeader(controlHello, 0, 0, uint32(len(nonce)), 0)
	return append(header, nonce...)
}

func controlHeader(frameType, code, operation uint8, payloadLength uint32, requestID uint64) []byte {
	header := make([]byte, ControlHeaderBytes)
	binary.BigEndian.PutUint32(header, controlMagic)
	header[4], header[5], header[6], header[7] = ControlVersion, frameType, code, operation
	binary.BigEndian.PutUint32(header[8:12], payloadLength)
	binary.BigEndian.PutUint64(header[12:20], requestID)
	return header
}

func decodeControlHeader(header []byte, frameType uint8) (ControlOperation, uint64, int, bool) {
	if len(header) != ControlHeaderBytes || binary.BigEndian.Uint32(header) != controlMagic || header[4] != ControlVersion || header[5] != frameType {
		return 0, 0, 0, false
	}
	size := binary.BigEndian.Uint32(header[8:12])
	requestID := binary.BigEndian.Uint64(header[12:20])
	if requestID == 0 || size > ControlMaxRequestPayload {
		return 0, 0, 0, false
	}
	return ControlOperation(header[6]), requestID, int(size), true
}

func controlTag(key, nonce, frame []byte) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write(nonce)
	_, _ = mac.Write(frame)
	return mac.Sum(nil)
}

func encodeControlResponse(key, nonce []byte, operation ControlOperation, requestID uint64, status ControlStatusCode, payload []byte) []byte {
	if len(payload) > ControlMaxResponsePayload {
		status, payload = ControlInternal, nil
	}
	header := controlHeader(controlResponse, uint8(status), uint8(operation), uint32(len(payload)), requestID)
	frame := append(header, payload...)
	return append(frame, controlTag(key, nonce, frame)...)
}

func CustomCAPath(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), "custom-ca.pem")
}
