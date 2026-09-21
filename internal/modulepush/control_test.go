package modulepush

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestControlSettingsStatusAndBarkTest(t *testing.T) {
	dir := t.TempDir()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"code":200}`))
	}))
	defer server.Close()
	config := Config{Version: 1}
	sender := NewSender(config)
	sender.Client.Transport = server.Client().Transport
	control := ControlServer{ConfigPath: filepath.Join(dir, "config.json"), CustomCAPath: filepath.Join(dir, "custom-ca.pem"), Sender: sender}
	settings, _ := json.Marshal(ControlSettings{
		BarkURL: pointerTo(server.URL + "/device-key"), BarkCallSound: true,
		ShowCallNumber: true, ShowSMSBody: true,
	})
	if status, _ := control.perform(ControlSettingsOperation, settings); status != ControlOK {
		t.Fatal("settings rejected", status)
	}
	status := control.status()
	if !status.BarkConfigured || status.BarkHost != "127.0.0.1" || !status.ShowCallNumber || !status.ShowSMSBody {
		t.Fatal(status)
	}
	encoded, err := os.ReadFile(control.ConfigPath)
	if err != nil || !json.Valid(encoded) {
		t.Fatal("configuration was not persisted", err)
	}
	if testStatus, _ := control.perform(ControlTestBarkOperation, nil); testStatus != ControlOK {
		t.Fatal("Bark test failed", testStatus)
	}
}

func pointerTo(value string) *string { return &value }

func TestControlCertificateImportAndRemoval(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "DJOneHub Test CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	control := ControlServer{ConfigPath: filepath.Join(dir, "config.json"), CustomCAPath: filepath.Join(dir, "custom-ca.pem"), Sender: NewSender(Config{Version: 1})}
	if status, _ := control.perform(ControlCertificateOperation, der); status != ControlOK {
		t.Fatal("DER certificate rejected", status)
	}
	info, err := os.Stat(control.CustomCAPath)
	if err != nil || info.Mode().Perm()&0077 != 0 || !control.status().CustomCA {
		t.Fatal("certificate not stored privately", err)
	}
	private, _ := x509.MarshalPKCS8PrivateKey(key)
	privatePEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private})
	if status, _ := control.perform(ControlCertificateOperation, privatePEM); status != ControlInvalidConfiguration {
		t.Fatal("private key accepted", status)
	}
	if status, _ := control.perform(ControlCertificateOperation, nil); status != ControlOK || control.status().CustomCA {
		t.Fatal("certificate removal failed", status)
	}
}

func TestControlFramesAuthenticateNonceAndRequest(t *testing.T) {
	key := make([]byte, 32)
	nonce := make([]byte, ControlNonceBytes)
	_, _ = rand.Read(key)
	_, _ = rand.Read(nonce)
	hello := encodeControlHello(nonce)
	if len(hello) != ControlHeaderBytes+ControlNonceBytes || string(hello[:4]) != "DJON" {
		t.Fatal("invalid hello")
	}
	payload := []byte(`{"bark_url":""}`)
	header := controlHeader(controlRequest, uint8(ControlSettingsOperation), 0, uint32(len(payload)), 42)
	frame := append(append([]byte{}, header...), payload...)
	tag := controlTag(key, nonce, frame)
	response := encodeControlResponse(key, nonce, ControlSettingsOperation, 42, ControlOK, payload)
	if len(tag) != ControlTagBytes || len(response) != ControlHeaderBytes+len(payload)+ControlTagBytes {
		t.Fatal("invalid authenticated frame")
	}
	response[len(response)-1] ^= 1
	want := controlTag(key, nonce, response[:len(response)-ControlTagBytes])
	if hmacEqual(want, response[len(response)-ControlTagBytes:]) {
		t.Fatal("tampered frame authenticated")
	}
}

func hmacEqual(left, right []byte) bool {
	if len(left) != len(right) {
		return false
	}
	var difference byte
	for index := range left {
		difference |= left[index] ^ right[index]
	}
	return difference == 0
}

func TestRingtoneSettingsPersistenceAndCompatibility(t *testing.T) {
	control := ControlServer{ConfigPath: filepath.Join(t.TempDir(), "config.json"), Sender: NewSender(Config{Version: 1, BarkURL: "https://example.com/secret"})}
	save := func(payload string, want ControlStatusCode) {
		t.Helper()
		if got, _ := control.perform(ControlSettingsOperation, []byte(payload)); got != want {
			t.Fatalf("status %v, want %v", got, want)
		}
	}
	save(`{"bark_call_ringtone":" alarm ","bark_sms_ringtone":"自定义","bark_call_sound":true}`, ControlOK)
	save(`{"bark_call_sound":false}`, ControlOK)
	var persisted Config
	if err := ReadPrivateJSON(control.ConfigPath, &persisted); err != nil {
		t.Fatal(err)
	}
	if persisted.BarkCallRingtone != "alarm" || persisted.BarkSMSRingtone != "自定义" || persisted.BarkURL != "https://example.com/secret" {
		t.Fatal("old client lost preferences or credentials")
	}
	save(`{"bark_call_ringtone":"../invalid"}`, ControlInvalidConfiguration)
	if control.status().BarkCallRingtone != "alarm" {
		t.Fatal("invalid update changed state")
	}
	save(`{"bark_call_ringtone":"","bark_sms_ringtone":""}`, ControlOK)
	if control.status().BarkCallRingtone != "" || control.status().BarkSMSRingtone != "" {
		t.Fatal("cannot reset sounds")
	}
}
