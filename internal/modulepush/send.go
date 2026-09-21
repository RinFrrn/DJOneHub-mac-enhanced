package modulepush

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

type Sender struct {
	Config   Config
	Client   *http.Client
	configMu sync.RWMutex
	clientMu sync.RWMutex
	authMu   sync.Mutex
	auth     map[string]cachedAuth
}

func (s *Sender) ConfigSnapshot() Config {
	s.configMu.RLock()
	defer s.configMu.RUnlock()
	return s.Config
}

func (s *Sender) UpdateConfig(config Config) {
	s.configMu.Lock()
	s.Config = config
	s.configMu.Unlock()
	s.authMu.Lock()
	s.auth = nil
	s.authMu.Unlock()
}

func (s *Sender) ReloadCustomCA(path string) error {
	roots, err := x509.SystemCertPool()
	if err != nil {
		return errors.New("cannot load system CA certificates")
	}
	if data, readErr := os.ReadFile(path); readErr == nil {
		if !roots.AppendCertsFromPEM(data) {
			return errors.New("cannot load custom CA certificate")
		}
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return errors.New("cannot read custom CA certificate")
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}
	s.clientMu.Lock()
	s.Client.Transport = transport
	s.clientMu.Unlock()
	return nil
}

func (s *Sender) do(request *http.Request) (*http.Response, error) {
	s.clientMu.RLock()
	defer s.clientMu.RUnlock()
	return s.Client.Do(request)
}

type cachedAuth struct {
	header string
	until  time.Time
}
type webPushClient struct{ sender *Sender }

// Apple asks providers not to refresh a VAPID JWT more than once per hour.
// webpush-go generates one per request, so retain the generated header by
// origin for an hour (the library signs it with a twelve-hour expiry).
func (c webPushClient) Do(request *http.Request) (*http.Response, error) {
	s := c.sender
	origin := request.URL.Scheme + "://" + request.URL.Host
	s.authMu.Lock()
	if s.auth == nil {
		s.auth = make(map[string]cachedAuth)
	}
	if cached, ok := s.auth[origin]; ok && time.Now().Before(cached.until) {
		request.Header.Set("Authorization", cached.header)
	} else {
		s.auth[origin] = cachedAuth{request.Header.Get("Authorization"), time.Now().Add(time.Hour)}
	}
	s.authMu.Unlock()
	return s.do(request)
}

type Result struct {
	Retry bool
	Code  int
	Err   error
}

func NewSender(config Config) *Sender {
	return &Sender{Config: config, Client: &http.Client{
		Timeout: 8 * time.Second,
		// Never forward a Bark device key or a push subscription to a redirect.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

func (s *Sender) Send(ctx context.Context, d Delivery) Result {
	config := s.ConfigSnapshot()
	if !time.Now().Before(d.Expires) {
		return Result{Err: errors.New("notification expired")}
	}
	ctx, cancel := context.WithDeadline(ctx, d.Expires)
	defer cancel()
	title, body := "DJOneHub 新短信", "模块收到新短信，请打开 DJOneHub 查看。"
	if d.Kind == "call" {
		title, body = "DJOneHub 来电", "模块有电话呼入，请打开 DJOneHub 接听。"
		if d.Detail != "" {
			body = "来电号码：" + d.Detail + "。请打开 DJOneHub 接听。"
		}
	} else if d.Kind == "sms" && d.Detail != "" {
		body = d.Detail
	}
	if d.Kind == "test" {
		title, body = "DJOneHub 通知测试", "推送通道已连接；真实来电和短信还需分别验证。"
	}
	var response *http.Response
	var err error
	switch d.Transport {
	case "bark":
		if config.BarkURL == "" {
			return Result{Err: errors.New("Bark is not configured")}
		}
		payload := map[string]any{"title": title, "body": body, "group": "DJOneHub", "level": "active", "isArchive": 0}
		payload["url"] = "djonehub://module"
		switch d.Kind {
		case "call":
			payload["url"] = "djonehub://calls"
			if config.BarkCallRingtone != "" {
				payload["sound"] = config.BarkCallRingtone
			}
		case "sms":
			payload["url"] = "djonehub://messages"
			if config.BarkSMSRingtone != "" {
				payload["sound"] = config.BarkSMSRingtone
			}
		}
		if d.Kind == "call" {
			payload["level"] = "timeSensitive"
			if config.BarkCallSound {
				payload["call"] = 1
			}
		}
		data, _ := json.Marshal(payload)
		request, requestErr := http.NewRequestWithContext(ctx, http.MethodPost, config.BarkURL, bytes.NewReader(data))
		if requestErr != nil {
			return Result{Err: errors.New("invalid Bark endpoint")}
		}
		request.Header.Set("Content-Type", "application/json")
		response, err = s.do(request)
	case "webpush":
		if config.WebPush.Subscription == nil {
			return Result{Err: errors.New("Web Push is not configured")}
		}
		payload, _ := json.Marshal(map[string]any{"title": title, "body": body, "tag": d.ID, "kind": d.Kind, "expires": d.Expires.UnixMilli()})
		ttl := max(0, int(time.Until(d.Expires).Seconds()))
		response, err = webpush.SendNotificationWithContext(ctx, payload, config.WebPush.Subscription, &webpush.Options{
			HTTPClient: webPushClient{s}, Subscriber: strings.TrimPrefix(config.WebPush.Subscriber, "mailto:"),
			VAPIDPublicKey: config.WebPush.PublicKey, VAPIDPrivateKey: config.WebPush.PrivateKey,
			TTL: ttl, Urgency: webpush.UrgencyHigh,
		})
	default:
		return Result{Err: errors.New("unknown transport")}
	}
	// HTTP errors commonly contain the complete secret URL. Never return them.
	if err != nil {
		return Result{Retry: true, Err: errors.New("push transport failed (check connectivity, CA certificates and clock)")}
	}
	defer response.Body.Close()
	code := response.StatusCode
	data, readErr := io.ReadAll(io.LimitReader(response.Body, 8193))
	if code >= 200 && code < 300 {
		if d.Transport == "bark" {
			var receipt struct {
				Code int `json:"code"`
			}
			if readErr != nil || len(data) > 8192 || json.Unmarshal(data, &receipt) != nil {
				return Result{Code: code, Retry: true, Err: errors.New("invalid Bark receipt")}
			}
			if receipt.Code != 200 {
				return Result{Code: receipt.Code, Retry: receipt.Code == 429 || receipt.Code >= 500, Err: errors.New("Bark rejected notification")}
			}
		}
		return Result{Code: code}
	}
	return Result{Code: code, Retry: code == 429 || code == 408 || code >= 500, Err: errors.New("push service rejected notification")}
}
