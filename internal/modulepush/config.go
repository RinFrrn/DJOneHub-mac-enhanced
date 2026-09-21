// Package modulepush delivers module-local events without a DJOneHub relay.
package modulepush

import (
	"bytes"
	"crypto/ecdh"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"unicode"

	webpush "github.com/SherClockHolmes/webpush-go"
)

type Config struct {
	BarkCallRingtone string `json:"bark_call_ringtone,omitempty"`
	BarkSMSRingtone  string `json:"bark_sms_ringtone,omitempty"`
	Version          int    `json:"version"`
	BarkURL          string `json:"bark_url,omitempty"`
	BarkCallSound    bool   `json:"bark_call_sound"`
	Privacy          struct {
		ShowCallNumber bool `json:"show_call_number"`
		ShowSMSBody    bool `json:"show_sms_body"`
	} `json:"privacy"`
	WebPush WebPushConfig `json:"web_push"`
}

type WebPushConfig struct {
	PublicKey    string                `json:"public_key"`
	PrivateKey   string                `json:"private_key"`
	Subscriber   string                `json:"subscriber"`
	Subscription *webpush.Subscription `json:"subscription,omitempty"`
}

type EventOptions struct {
	Transports     []string
	ShowCallNumber bool
	ShowSMSBody    bool
}

func (c Config) EventOptions() EventOptions {
	return EventOptions{
		Transports:     c.Transports(),
		ShowCallNumber: c.Privacy.ShowCallNumber,
		ShowSMSBody:    c.Privacy.ShowSMSBody,
	}
}

func HTTPSURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "https" && u.Hostname() != "" && u.User == nil && u.Fragment == ""
}

func (c Config) Validate() error {
	for _, sound := range []string{c.BarkCallRingtone, c.BarkSMSRingtone} {
		if len(sound) > 128 || strings.ContainsAny(sound, "/\\") || strings.IndexFunc(sound, unicode.IsControl) >= 0 {
			return errors.New("invalid Bark sound name")
		}
	}
	if c.Version != 1 {
		return errors.New("unsupported configuration version")
	}
	if c.BarkURL != "" {
		u, err := url.Parse(c.BarkURL)
		if err != nil || !HTTPSURL(c.BarkURL) || u.RawQuery != "" || strings.Trim(u.Path, "/") == "" {
			return errors.New("Bark requires an HTTPS base URL ending in the device key, without test text or query parameters")
		}
	}
	if s := c.WebPush.Subscription; s != nil {
		if !HTTPSURL(s.Endpoint) || s.Keys.Auth == "" || s.Keys.P256dh == "" || c.WebPush.PublicKey == "" || c.WebPush.PrivateKey == "" {
			return errors.New("incomplete Web Push subscription or VAPID key pair")
		}
		if !strings.HasPrefix(c.WebPush.Subscriber, "mailto:") && !HTTPSURL(c.WebPush.Subscriber) {
			return errors.New("Web Push requires a mailto: or HTTPS contact")
		}
		if strings.HasPrefix(c.WebPush.Subscriber, "mailto:") && !strings.Contains(strings.TrimPrefix(c.WebPush.Subscriber, "mailto:"), "@") {
			return errors.New("Web Push mail contact is incomplete")
		}
		decode := func(value string) ([]byte, error) {
			return base64.RawURLEncoding.DecodeString(strings.TrimRight(value, "="))
		}
		auth, err := decode(s.Keys.Auth)
		if err != nil || len(auth) != 16 {
			return errors.New("invalid subscription authentication key")
		}
		public, err := decode(s.Keys.P256dh)
		if err != nil {
			return errors.New("invalid subscription public key")
		}
		if _, err := ecdh.P256().NewPublicKey(public); err != nil {
			return errors.New("invalid subscription public key")
		}
		private, err := decode(c.WebPush.PrivateKey)
		if err != nil {
			return errors.New("invalid VAPID private key")
		}
		key, err := ecdh.P256().NewPrivateKey(private)
		if err != nil {
			return errors.New("invalid VAPID private key")
		}
		vapidPublic, err := decode(c.WebPush.PublicKey)
		if err != nil || !bytes.Equal(key.PublicKey().Bytes(), vapidPublic) {
			return errors.New("VAPID public and private keys do not match")
		}
	}
	return nil
}

func ReadPrivateJSON(path string, value any) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	link, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || link.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return errors.New("private file must be regular, not a symlink, and mode 0600")
	}
	d := json.NewDecoder(io.LimitReader(f, 1<<20))
	d.DisallowUnknownFields()
	if err := d.Decode(value); err != nil {
		return errors.New("invalid private JSON file")
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return errors.New("trailing JSON data")
	}
	return nil
}

func WritePrivateJSON(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return WritePrivateFile(path, append(data, '\n'))
}

func WritePrivateFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".notify-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Rename(f.Name(), path); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func (c Config) Transports() []string {
	var result []string
	if c.BarkURL != "" {
		result = append(result, "bark")
	}
	if c.WebPush.Subscription != nil {
		result = append(result, "webpush")
	}
	return result
}
