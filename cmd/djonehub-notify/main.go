// djonehub-notify runs on the module. Its only listener is the authenticated
// configuration service bound to the USB ECM address.
package main

import (
	"bufio"
	"context"
	"crypto/fips140"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/iniwex5/vohive/internal/modulepairing"
	"github.com/iniwex5/vohive/internal/modulepush"
)

func main() {
	if err := run(); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}

func run() (runErr error) {
	// The QDC507 has about 43 MiB RAM. Go's FIPS entropy source needs a
	// 32 MiB scratch buffer, so enabling it cannot coexist with this daemon.
	if fips140.Enabled() {
		return errors.New("FIPS mode is unsupported on the low-memory QDC507")
	}
	configPath := flag.String("config", "/usrdata/djonehub/notify/config.json", "private configuration file")
	statePath := flag.String("state", "", "private durable state; defaults beside config")
	initialize := flag.Bool("init", false, "create private config and per-module VAPID keys")
	contact := flag.String("contact", "", "Web Push contact, mailto:address or HTTPS URL")
	barkFile := flag.String("bark-url-file", "", "import Bark base URL from a private text file")
	subscriptionFile := flag.String("subscription", "", "import PWA subscription export")
	check := flag.Bool("check", false, "validate configuration without sending")
	probe := flag.Bool("probe-network", false, "check TLS connectivity to Bark and Apple without sending notifications")
	probeRuntimeFlag := flag.Bool("probe-runtime", false, "observe QMI for 30 seconds without sending, then remove temporary state")
	logFile := flag.String("log-file", "", "bounded private diagnostic log (256 KiB plus one previous file)")
	test := flag.String("test", "", "send one test: bark or webpush")
	monitor := flag.String("monitor", "/usrdata/djonehub/notify/djonehub-notify-monitor.armv7", "read-only QMI monitor executable")
	controlAddress := flag.String("control-address", "192.168.225.1:45753", "authenticated iOS configuration listener")
	pairingKey := flag.String("pairing-key", "/usrdata/djonehub/voice-test/pairing.key", "existing module control pairing key")
	pairingRegistry := flag.String("experimental-pairing-registry", "", "opt-in TLS authorization registry with short-lived voice sessions")
	voiceSessions := flag.String("voice-sessions", "/run/djonehub/voice-sessions.v1", "volatile voice-control session registry")
	flag.Parse()
	if *logFile != "" {
		if err := os.MkdirAll(filepath.Dir(*logFile), 0700); err != nil {
			return err
		}
		writer, err := modulepush.OpenLog(*logFile)
		if err != nil {
			return err
		}
		previous := log.Writer()
		log.SetOutput(writer)
		defer func() {
			if runErr != nil {
				log.Print(runErr)
			}
			log.SetOutput(previous)
			_ = writer.Close()
		}()
	}
	if *probe {
		return probeNetwork()
	}
	if *probeRuntimeFlag {
		return probeRuntime(*monitor, filepath.Dir(*configPath))
	}
	if *statePath == "" {
		*statePath = filepath.Join(filepath.Dir(*configPath), "state.json")
	}
	if *statePath == *configPath {
		return errors.New("state and config paths must differ")
	}
	var config modulepush.Config
	if *initialize {
		if _, err := os.Lstat(*configPath); !errors.Is(err, os.ErrNotExist) {
			return errors.New("init requires a new config path; existing keys will not be replaced")
		}
		config.Version = 1
		config.BarkCallSound = true
		config.WebPush.Subscriber = "https://github.com/iniwex5/vohive"
		private, public, err := webpush.GenerateVAPIDKeys()
		if err != nil {
			return errors.New("cannot generate VAPID keys")
		}
		config.WebPush.PrivateKey, config.WebPush.PublicKey = private, public
	} else if err := modulepush.ReadPrivateJSON(*configPath, &config); err != nil {
		return err
	}
	if *barkFile != "" {
		info, err := os.Lstat(*barkFile)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 4096 {
			return errors.New("Bark URL file must be a small private regular file (chmod 600)")
		}
		data, err := os.ReadFile(*barkFile)
		if err != nil {
			return err
		}
		config.BarkURL = strings.TrimRight(strings.TrimSpace(string(data)), "/")
	}
	if *subscriptionFile != "" {
		// Export binds the subscription to the public key used by the webpage.
		var exported struct {
			Version      int                  `json:"version"`
			PublicKey    string               `json:"public_key"`
			Subscription webpush.Subscription `json:"subscription"`
		}
		if err := modulepush.ReadPrivateJSON(*subscriptionFile, &exported); err != nil {
			return err
		}
		if exported.Version != 1 || exported.PublicKey != config.WebPush.PublicKey {
			return errors.New("subscription belongs to another VAPID key; subscribe with this module's public key")
		}
		config.WebPush.Subscription = &exported.Subscription
	}
	if *contact != "" {
		config.WebPush.Subscriber = *contact
	}
	if err := config.Validate(); err != nil {
		return err
	}
	if *initialize || *barkFile != "" || *subscriptionFile != "" || *contact != "" {
		if err := modulepush.WritePrivateJSON(*configPath, config); err != nil {
			return err
		}
		fmt.Printf("Saved private config. Web Push public key: %s\n", config.WebPush.PublicKey)
		return nil
	}
	if len(config.Transports()) == 0 {
		if *check {
			fmt.Printf("Configuration valid. No push destination is enabled; configure one from the iOS app.\n")
			return nil
		}
	}
	if *check {
		fmt.Printf("Configuration valid. Enabled: %s\n", strings.Join(config.Transports(), ", "))
		return nil
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	sender := modulepush.NewSender(config)
	if err := sender.ReloadCustomCA(modulepush.CustomCAPath(*configPath)); err != nil {
		return err
	}
	if *test != "" {
		result := sender.Send(ctx, modulepush.Delivery{ID: "test", Kind: "test", Transport: *test, Expires: time.Now().Add(30 * time.Second)})
		if result.Err != nil {
			return fmt.Errorf("test failed: code=%d: %w", result.Code, result.Err)
		}
		fmt.Printf("Push service accepted test (%d). Confirm receipt on the phone.\n", result.Code)
		return nil
	}
	if *pairingRegistry != "" {
		store, err := modulepairing.Open(*pairingRegistry)
		if err != nil {
			return err
		}
		defer store.Close()
		if _, err := store.TLSConfig(); err != nil {
			return err
		}
		listener, err := net.Listen("tcp4", net.JoinHostPort(modulepairing.Host, strconv.Itoa(modulepairing.Port)))
		if err != nil {
			return errors.New("cannot listen for module authorization")
		}
		defer listener.Close()
		managedContext, cancel := context.WithCancel(ctx)
		defer cancel()
		results := make(chan error, 2)
		sessions := &modulepairing.SessionRegistry{Path: *voiceSessions}
		go func() {
			results <- (modulepairing.Server{Store: store, Sessions: sessions}).Serve(managedContext, listener)
		}()
		go func() {
			results <- serveManaged(managedContext, sender, *monitor, *statePath, *controlAddress, *pairingKey, *voiceSessions, *configPath)
		}()
		first := <-results
		cancel()
		<-results
		return first
	}
	return serveManaged(ctx, sender, *monitor, *statePath, *controlAddress, *pairingKey, "", *configPath)
}

func serveManaged(ctx context.Context, sender *modulepush.Sender, monitor, statePath, controlAddress, pairingKey, sessionFile, configPath string) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make(chan error, 2)
	go func() { results <- serve(ctx, sender, monitor, statePath) }()
	control := modulepush.ControlServer{
		Address: controlAddress, PairingKey: pairingKey, SessionFile: sessionFile, ConfigPath: configPath,
		CustomCAPath: modulepush.CustomCAPath(configPath), Sender: sender,
	}
	go func() { results <- control.Serve(ctx) }()
	err := <-results
	cancel()
	<-results
	return err
}

func probeNetwork() error {
	defer reportMemory()
	client := modulepush.NewSender(modulepush.Config{}).Client
	for _, target := range []struct{ name, url string }{
		{"Bark", "https://api.day.app/"},
		{"Apple Web Push", "https://web.push.apple.com/"},
	} {
		response, err := client.Get(target.url)
		if err != nil {
			return fmt.Errorf("%s TLS probe failed; check module network, CA bundle and UTC clock", target.name)
		}
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		_ = response.Body.Close()
		if response.TLS == nil || len(response.TLS.VerifiedChains) == 0 {
			return errors.New("TLS peer was not verified")
		}
		fmt.Printf("%s: verified TLS, HTTP %d (connectivity only; no push sent)\n", target.name, response.StatusCode)
		if response.StatusCode == http.StatusProxyAuthRequired {
			return errors.New("network proxy requires authentication")
		}
	}
	return nil
}

func reportMemory() {
	paths := map[string]bool{"/proc/self/status": true}
	// Linux 3.18 does not reliably expose task children. Find direct monitor
	// children by PPid in /proc instead, without invoking another process.
	statuses, _ := filepath.Glob("/proc/[0-9]*/status")
	parent := strconv.Itoa(os.Getpid())
	for _, path := range statuses {
		data, _ := os.ReadFile(path)
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "PPid:") && strings.TrimSpace(strings.TrimPrefix(line, "PPid:")) == parent {
				paths[path] = true
				break
			}
		}
	}
	total := 0
	for path := range paths {
		data, _ := os.ReadFile(path)
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "VmRSS:") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					kb, _ := strconv.Atoi(fields[1])
					total += kb
				}
			}
			if path == "/proc/self/status" && (strings.HasPrefix(line, "VmRSS:") || strings.HasPrefix(line, "VmHWM:")) {
				fmt.Println(line)
			}
		}
	}
	if total > 0 {
		fmt.Printf("Sender plus monitor RSS: %d KiB (shared pages counted per process)\n", total)
	}
}

func probeRuntime(monitor, directory string) error {
	dir, err := os.MkdirTemp(directory, ".notify-runtime-probe-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	counts := map[string]int{}
	reportAt := time.Now().Add(20 * time.Second)
	reported := false
	// No destination is configured, so even genuine arrivals cannot send.
	err = serveObserved(ctx, modulepush.NewSender(modulepush.Config{}), monitor, filepath.Join(dir, "state.json"), func(event modulepush.Snapshot) {
		key := event.Kind
		if key == "sms" {
			key += strconv.Itoa(event.Storage)
		}
		counts[key]++
		if !reported && time.Now().After(reportAt) {
			reportMemory()
			reported = true
		}
	})
	if err != nil {
		return err
	}
	if counts["calls"] < 2 || counts["sms0"] < 2 || counts["sms1"] < 2 {
		return errors.New("runtime probe did not receive repeated complete Voice/SIM/NV snapshots")
	}
	fmt.Printf("Runtime probe passed: calls=%d SIM=%d NV=%d; no push sent; temporary state removed on exit\n", counts["calls"], counts["sms0"], counts["sms1"])
	return nil
}

type completed struct {
	delivery modulepush.Delivery
	result   modulepush.Result
}

func serve(ctx context.Context, sender *modulepush.Sender, monitor, statePath string) error {
	return serveObserved(ctx, sender, monitor, statePath, nil)
}

func serveObserved(ctx context.Context, sender *modulepush.Sender, monitor, statePath string, observe func(modulepush.Snapshot)) error {
	if err := os.MkdirAll(filepath.Dir(statePath), 0700); err != nil {
		return err
	}
	// Hold an OS lock, not a stale PID file. A second daemon would duplicate pushes.
	lock, err := os.OpenFile(statePath+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("notification daemon is already running for this state")
	}
	state := modulepush.NewState()
	if err := modulepush.ReadPrivateJSON(statePath, state); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if state.Version != 1 || len(state.Queue) > 256 {
		return errors.New("invalid notification state")
	}
	// A restart cannot establish that an old incoming call is still ringing.
	for i := range state.Queue {
		if state.Queue[i].Kind == "call" {
			state.Queue[i].Expires = time.Time{}
		}
	}
	state.Expire(time.Now())
	config := sender.ConfigSnapshot()
	if state.RedactQueuedDetails(config.Privacy.ShowCallNumber, config.Privacy.ShowSMSBody) {
		if err := modulepush.WritePrivateJSON(statePath, state); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithCancel(ctx)
	var watchers sync.WaitGroup
	defer func() { cancel(); watchers.Wait() }()
	events := make(chan modulepush.Snapshot, 8)
	errorsCh := make(chan error, 2)
	done := make(chan completed, 2)
	for _, mode := range []string{"--calls", "--sms"} {
		watchers.Add(1)
		go func(mode string) { defer watchers.Done(); errorsCh <- watch(ctx, monitor, mode, events) }(mode)
	}
	inflight := map[string]context.CancelFunc{}
	inflightID := map[string]string{}
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	log.Printf("notification daemon started; transports=%s; call-number=%t SMS-body=%t", strings.Join(config.Transports(), ","), config.Privacy.ShowCallNumber, config.Privacy.ShowSMSBody)
	for {
		changed := false
		select {
		case <-ctx.Done():
			return nil
		case err := <-errorsCh:
			if ctx.Err() != nil {
				return nil
			}
			if err != nil {
				return err
			}
			return errors.New("QMI monitor stopped unexpectedly")
		case event := <-events:
			var err error
			changed, err = state.Apply(event, sender.ConfigSnapshot().EventOptions(), time.Now())
			if err != nil {
				return err
			}
			if observe != nil {
				observe(event)
			}
		case result := <-done:
			transport := result.delivery.Transport
			if cancelSend := inflight[transport]; cancelSend != nil {
				cancelSend()
			}
			delete(inflight, transport)
			delete(inflightID, transport)
			changed = state.Finish(result.delivery.ID, transport, result.result.Retry, time.Now())
			if result.result.Err != nil {
				log.Printf("push kind=%s transport=%s code=%d retry=%t: %s", result.delivery.Kind, transport, result.result.Code, result.result.Retry, result.result.Err)
			} else {
				log.Printf("push accepted kind=%s transport=%s code=%d", result.delivery.Kind, transport, result.result.Code)
			}
		case <-tick.C:
		}
		if state.Reconcile(sender.ConfigSnapshot().EventOptions()) {
			changed = true
		}
		if state.Expire(time.Now()) {
			changed = true
		}
		if changed {
			// Persist before network dispatch: a reboot can retry, never silently
			// mark a new message delivered before its request was attempted.
			if err := modulepush.WritePrivateJSON(statePath, state); err != nil {
				return err
			}
		}
		for transport, id := range inflightID {
			present := false
			for _, d := range state.Queue {
				if d.ID == id && d.Transport == transport {
					present = true
					break
				}
			}
			if !present {
				inflight[transport]()
			}
		}
		// Dispatch calls first; no network work runs in the QMI event loop.
		for _, kind := range []string{"call", "sms"} {
			for _, delivery := range state.Queue {
				if delivery.Kind != kind || inflight[delivery.Transport] != nil || time.Now().Before(delivery.Next) {
					continue
				}
				sendCtx, cancelSend := context.WithCancel(ctx)
				inflight[delivery.Transport], inflightID[delivery.Transport] = cancelSend, delivery.ID
				go func(d modulepush.Delivery) {
					result := sender.Send(sendCtx, d)
					select {
					case done <- completed{d, result}:
					case <-ctx.Done():
					}
				}(delivery)
			}
		}
	}
}

func watch(ctx context.Context, executable, mode string, events chan<- modulepush.Snapshot) error {
	cmd := exec.CommandContext(ctx, executable, mode)
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 6 * time.Second
	// The monitor stderr contains QMI diagnostics only, never PDUs or secrets.
	cmd.Stderr = log.Writer()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return errors.New("cannot create QMI monitor pipe")
	}
	if err = cmd.Start(); err != nil {
		return errors.New("cannot start QMI monitor; check executable path and target ABI")
	}
	err = readEvents(ctx, stdout, events)
	if err != nil {
		_ = cmd.Process.Kill()
	}
	waitErr := cmd.Wait()
	if err != nil {
		return err
	}
	if waitErr != nil {
		return errors.New("QMI monitor exited with failure")
	}
	return nil
}

func readEvents(ctx context.Context, reader io.Reader, events chan<- modulepush.Snapshot) error {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 4096), 300000)
	for scanner.Scan() {
		var event modulepush.Snapshot
		if json.Unmarshal(scanner.Bytes(), &event) != nil {
			return errors.New("invalid QMI monitor frame")
		}
		select {
		case events <- event:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if scanner.Err() != nil {
		return errors.New("cannot read QMI monitor stream")
	}
	return nil
}
