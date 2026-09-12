package modulepush

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/hkdf"
)

func TestBarkPayloadReceiptAndErrors(t *testing.T) {
	for _, tc := range []struct {
		name        string
		status      int
		body        string
		retry, fail bool
	}{
		{"accepted", 200, `{"code":200}`, false, false},
		{"application rejection", 200, `{"code":400}`, false, true},
		{"application overload", 200, `{"code":500}`, true, true},
		{"malformed", 200, `not json`, true, true},
		{"invalid key", 404, `{}`, false, true},
		{"rate limited", 429, `{}`, true, true},
		{"server failure", 503, `{}`, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "POST" || r.URL.Path != "/secret" || r.Header.Get("Content-Type") != "application/json" {
					t.Error("invalid Bark request")
				}
				var payload map[string]any
				if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
					t.Error(err)
				}
				if payload["call"] != float64(1) || payload["level"] != "timeSensitive" || payload["body"] != "模块有电话呼入，请打开 DJOneHub 接听。" {
					t.Error(payload)
				}
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			sender := NewSender(Config{BarkURL: server.URL + "/secret", BarkCallSound: true})
			sender.Client.Transport = server.Client().Transport
			result := sender.Send(context.Background(), Delivery{Kind: "call", Transport: "bark", Expires: time.Now().Add(time.Minute)})
			if result.Retry != tc.retry || (result.Err != nil) != tc.fail {
				t.Fatal(result)
			}
		})
	}
}

func TestBarkUsesOnlyOptedInDeliveryDetail(t *testing.T) {
	var bodies []string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			Body string `json:"body"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		bodies = append(bodies, payload.Body)
		_, _ = io.WriteString(w, `{"code":200}`)
	}))
	defer server.Close()
	sender := NewSender(Config{BarkURL: server.URL + "/secret"})
	sender.Client.Transport = server.Client().Transport
	for _, delivery := range []Delivery{
		{Kind: "call", Detail: "+8613800138000", Transport: "bark", Expires: time.Now().Add(time.Minute)},
		{Kind: "sms", Detail: "验证码 123456", Transport: "bark", Expires: time.Now().Add(time.Minute)},
	} {
		if result := sender.Send(context.Background(), delivery); result.Err != nil {
			t.Fatal(result.Err)
		}
	}
	if len(bodies) != 2 || !strings.Contains(bodies[0], "+8613800138000") || bodies[1] != "验证码 123456" {
		t.Fatal(bodies)
	}
}

func TestNoRedirectAndNoCredentialInErrors(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://example.invalid/stolen", http.StatusTemporaryRedirect)
	}))
	sender := NewSender(Config{BarkURL: server.URL + "/very-secret-key"})
	sender.Client.Transport = server.Client().Transport
	delivery := Delivery{Kind: "test", Transport: "bark", Expires: time.Now().Add(time.Minute)}
	result := sender.Send(context.Background(), delivery)
	if result.Code != 307 || result.Retry {
		t.Fatal(result)
	}
	server.Close()
	result = sender.Send(context.Background(), delivery)
	if result.Err == nil || strings.Contains(result.Err.Error(), "very-secret-key") || strings.Contains(result.Err.Error(), server.URL) {
		t.Fatal("secret leaked", result)
	}
}

func TestWebPushReusesAuthenticationForOneHour(t *testing.T) {
	var headers []string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		headers = append(headers, r.Header.Get("Authorization"))
		w.WriteHeader(201)
	}))
	defer server.Close()
	sender := NewSender(Config{})
	sender.Client.Transport = server.Client().Transport
	client := webPushClient{sender}
	for _, header := range []string{"first-token", "second-token"} {
		r, _ := http.NewRequest("POST", server.URL, nil)
		r.Header.Set("Authorization", header)
		response, err := client.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
	}
	if len(headers) != 2 || headers[0] != headers[1] {
		t.Fatal("VAPID changed between consecutive pushes", headers)
	}
	sender.auth[server.URL] = cachedAuth{header: "first-token", until: time.Now().Add(-time.Second)}
	r, _ := http.NewRequest("POST", server.URL, nil)
	r.Header.Set("Authorization", "renewed-token")
	response, err := client.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if headers[2] != "renewed-token" {
		t.Fatal("expired VAPID was reused")
	}
}

func TestWebPushDecryptAndVerifyVAPID(t *testing.T) {
	// Act as the browser, independently decrypt RFC 8291 content and verify JWT.
	receiver, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	auth := make([]byte, 16)
	_, _ = rand.Read(auth)
	private, public, err := webpush.GenerateVAPIDKeys()
	if err != nil {
		t.Fatal(err)
	}
	config := Config{Version: 1}
	config.WebPush.PublicKey, config.WebPush.PrivateKey, config.WebPush.Subscriber = public, private, "mailto:test@example.com"
	var endpoint string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Encoding") != "aes128gcm" || r.Header.Get("Urgency") != "high" {
			t.Error("invalid push headers")
		}
		authorization := r.Header.Get("Authorization")
		parts := strings.Split(strings.TrimPrefix(authorization, "vapid t="), ", k=")
		if len(parts) != 2 || parts[1] != public {
			t.Error("invalid VAPID header")
			w.WriteHeader(400)
			return
		}
		pub, _ := base64.RawURLEncoding.DecodeString(public)
		x, y := elliptic.Unmarshal(elliptic.P256(), pub)
		u, _ := url.Parse(endpoint)
		token, err := jwt.Parse(parts[0], func(token *jwt.Token) (any, error) { return &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, nil }, jwt.WithValidMethods([]string{"ES256"}), jwt.WithAudience(u.Scheme+"://"+u.Host))
		if err != nil {
			t.Error(err)
		}
		if token != nil {
			if subject, err := token.Claims.GetSubject(); err != nil || subject != "mailto:test@example.com" {
				t.Error("invalid VAPID subject", subject, err)
			}
		}
		wire, _ := io.ReadAll(r.Body)
		if len(wire) < 102 || wire[20] != 65 {
			t.Error("invalid encrypted record")
			return
		}
		senderPublic, err := ecdh.P256().NewPublicKey(wire[21:86])
		if err != nil {
			t.Error(err)
			return
		}
		secret, err := receiver.ECDH(senderPublic)
		if err != nil {
			t.Error(err)
			return
		}
		derive := func(secret, salt, info []byte, size int) []byte {
			out := make([]byte, size)
			if _, err := io.ReadFull(hkdf.New(sha256.New, secret, salt, info), out); err != nil {
				t.Error(err)
			}
			return out
		}
		info := append([]byte("WebPush: info\x00"), receiver.PublicKey().Bytes()...)
		info = append(info, senderPublic.Bytes()...)
		ikm := derive(secret, auth, info, 32)
		key := derive(ikm, wire[:16], []byte("Content-Encoding: aes128gcm\x00"), 16)
		nonce := derive(ikm, wire[:16], []byte("Content-Encoding: nonce\x00"), 12)
		block, _ := aes.NewCipher(key)
		gcm, _ := cipher.NewGCM(block)
		plain, err := gcm.Open(nil, nonce, wire[86:], nil)
		if err != nil {
			t.Error(err)
			return
		}
		plain = bytes.TrimRight(plain, "\x00")
		if len(plain) == 0 || plain[len(plain)-1] != 2 {
			t.Error("invalid record delimiter")
			return
		}
		var payload map[string]any
		if err := json.Unmarshal(plain[:len(plain)-1], &payload); err != nil {
			t.Error(err)
		}
		if payload["kind"] != "sms" || payload["title"] != "DJOneHub 新短信" || payload["tag"] != "message-1" {
			t.Error(payload)
		}
		w.WriteHeader(http.StatusCreated)
	}))
	defer server.Close()
	endpoint = server.URL + "/subscription"
	config.WebPush.Subscription = &webpush.Subscription{Endpoint: endpoint, Keys: webpush.Keys{P256dh: base64.RawURLEncoding.EncodeToString(receiver.PublicKey().Bytes()), Auth: base64.RawURLEncoding.EncodeToString(auth)}}
	sender := NewSender(config)
	sender.Client.Transport = server.Client().Transport
	result := sender.Send(context.Background(), Delivery{ID: "message-1", Kind: "sms", Transport: "webpush", Expires: time.Now().Add(time.Minute)})
	if result.Err != nil || result.Code != 201 {
		t.Fatal(result)
	}
}

func TestPrivateConfigAndDurableState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "state.json")
	state := NewState()
	state.enqueue("sms", "message", []string{"bark"}, "", time.Now())
	if err := WritePrivateJSON(path, state); err != nil {
		t.Fatal(err)
	}
	loaded := NewState()
	if err := ReadPrivateJSON(path, loaded); err != nil {
		t.Fatal(err)
	}
	if len(loaded.Queue) != 1 {
		t.Fatal("lost pending delivery")
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if err := ReadPrivateJSON(path, loaded); err == nil {
		t.Fatal("accepted world-readable state")
	}
	for _, endpoint := range []string{"http://example.com/key", "https://user:pass@example.com/key", "https://example.com/key?q=secret", "https://example.com/"} {
		if err := (Config{Version: 1, BarkURL: endpoint}).Validate(); err == nil {
			t.Fatal(fmt.Sprintf("accepted %s", endpoint))
		}
	}
}
