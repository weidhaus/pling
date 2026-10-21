// pling-relay: watches ntfy topics and wakes Pling for iOS through APNs.
//
// Devices register their APNs token and topics with the same credentials they use for ntfy;
// the relay checks each topic with ntfy's /<topic>/auth and never stores those credentials.
// End-to-end encrypted messages pass through as ciphertext; the app's extension decrypts them.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

type Topic struct {
	Topic       string `json:"topic"`
	MinPriority int    `json:"min_priority"`
	MutedUntil  int64  `json:"muted_until"` // unix seconds, 0 = not muted
}

type Device struct {
	Sandbox bool    `json:"sandbox"`
	Server  string  `json:"server"` // the app's id for this server, echoed back in every push
	Topics  []Topic `json:"topics"`
}

type state struct {
	Devices map[string]Device `json:"devices"`
	LastID  string            `json:"last_id"`
}

type Relay struct {
	ntfy     *url.URL
	ntfyAuth string // Authorization header for the relay's own stream
	apns     *APNs
	path     string

	mu      sync.Mutex
	st      state
	changed chan struct{}
}

var (
	topicRe = regexp.MustCompile(`^[-_A-Za-z0-9]{1,64}$`)
	tokenRe = regexp.MustCompile(`^[0-9a-fA-F]{64,200}$`)
)

func main() {
	ntfy, err := url.Parse(env("NTFY_URL", "http://ntfy:80"))
	if err != nil {
		log.Fatal(err)
	}
	auth := ""
	if t := os.Getenv("NTFY_TOKEN"); t != "" {
		auth = "Bearer " + t
	} else if u := os.Getenv("NTFY_USER"); u != "" {
		auth = "Basic " + base64.StdEncoding.EncodeToString([]byte(u+":"+os.Getenv("NTFY_PASSWORD")))
	}
	apns, err := NewAPNs(must("APNS_KEY_FILE"), must("APNS_KEY_ID"), must("APNS_TEAM_ID"), env("APNS_TOPIC", "com.weidhaus.pling.ios"))
	if err != nil {
		log.Fatal(err)
	}
	r := &Relay{ntfy: ntfy, ntfyAuth: auth, apns: apns, path: filepath.Join(env("DATA_DIR", "/data"), "devices.json"), changed: make(chan struct{}, 1)}
	r.load()
	go r.watch(context.Background())

	mux := http.NewServeMux()
	mux.HandleFunc("PUT /v1/devices/{token}", r.register)
	mux.HandleFunc("DELETE /v1/devices/{token}", r.unregister)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	addr := env("LISTEN", ":8080")
	log.Printf("listening on %s, ntfy %s", addr, ntfy)
	log.Fatal(http.ListenAndServe(addr, mux))
}

// MARK: registration

func (r *Relay) register(w http.ResponseWriter, req *http.Request) {
	token := req.PathValue("token")
	var d Device
	if !tokenRe.MatchString(token) || json.NewDecoder(http.MaxBytesReader(w, req.Body, 64<<10)).Decode(&d) != nil || len(d.Topics) > 200 {
		log.Printf("register: bad request")
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	for _, t := range d.Topics {
		if !topicRe.MatchString(t.Topic) {
			http.Error(w, "bad topic", http.StatusBadRequest)
			return
		}
		ok, err := r.canRead(req.Context(), t.Topic, req.Header.Get("Authorization"))
		if err != nil {
			log.Printf("register %s…: %v", token[:8], err)
			http.Error(w, "ntfy unreachable", http.StatusBadGateway)
			return
		}
		if !ok {
			log.Printf("register %s…: no read access to %s", token[:8], t.Topic)
			http.Error(w, "no read access to "+t.Topic, http.StatusForbidden)
			return
		}
	}
	r.update(func(s *state) {
		if len(d.Topics) == 0 {
			delete(s.Devices, token)
		} else {
			s.Devices[token] = d
		}
	})
	log.Printf("registered %s… (sandbox=%v) for %d topics", token[:8], d.Sandbox, len(d.Topics))
	w.WriteHeader(http.StatusNoContent)
}

func (r *Relay) unregister(w http.ResponseWriter, req *http.Request) {
	token := req.PathValue("token")
	r.update(func(s *state) { delete(s.Devices, token) })
	w.WriteHeader(http.StatusNoContent)
}

func (r *Relay) canRead(ctx context.Context, topic, authorization string) (bool, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", r.ntfy.JoinPath(topic, "auth").String(), nil)
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false, err
	}
	resp.Body.Close()
	switch {
	case resp.StatusCode == 200:
		return true, nil
	case resp.StatusCode == 401 || resp.StatusCode == 403:
		return false, nil
	default:
		return false, fmt.Errorf("ntfy auth check: HTTP %d", resp.StatusCode)
	}
}

// MARK: state

func (r *Relay) load() {
	r.st = state{Devices: map[string]Device{}}
	if b, err := os.ReadFile(r.path); err == nil {
		json.Unmarshal(b, &r.st)
	}
	if r.st.Devices == nil {
		r.st.Devices = map[string]Device{}
	}
}

func (r *Relay) update(f func(*state)) {
	r.mu.Lock()
	before := strings.Join(r.topicsLocked(), ",")
	f(&r.st)
	b, _ := json.MarshalIndent(r.st, "", "  ")
	after := strings.Join(r.topicsLocked(), ",")
	r.mu.Unlock()
	if err := os.WriteFile(r.path+".tmp", b, 0o600); err == nil {
		os.Rename(r.path+".tmp", r.path)
	} else {
		log.Printf("save: %v", err)
	}
	if before != after {
		select {
		case r.changed <- struct{}{}:
		default:
		}
	}
}

func (r *Relay) topicsLocked() []string {
	set := map[string]bool{}
	for _, d := range r.st.Devices {
		for _, t := range d.Topics {
			set[t.Topic] = true
		}
	}
	out := make([]string, 0, len(set))
	for t := range set {
		out = append(out, t)
	}
	sort.Strings(out)
	return out
}

// MARK: ntfy stream

func (r *Relay) watch(ctx context.Context) {
	backoff := time.Second
	for {
		r.mu.Lock()
		topics, since := r.topicsLocked(), r.st.LastID
		r.mu.Unlock()
		if len(topics) == 0 {
			<-r.changed
			continue
		}
		sctx, cancel := context.WithCancel(ctx)
		done := make(chan error, 1)
		go func() { done <- r.stream(sctx, topics, since, func() { backoff = time.Second }) }()
		select {
		case <-r.changed:
			cancel()
			<-done
			continue
		case err := <-done:
			cancel()
			log.Printf("stream ended: %v", err)
		}
		time.Sleep(backoff)
		backoff = min(backoff*2, time.Minute)
	}
}

func (r *Relay) stream(ctx context.Context, topics []string, since string, connected func()) error {
	u := r.ntfy.JoinPath(strings.Join(topics, ","), "json")
	if since != "" { // without it, ntfy streams only new messages
		u.RawQuery = url.Values{"since": {since}}.Encode()
	}
	req, _ := http.NewRequestWithContext(ctx, "GET", u.String(), nil)
	if r.ntfyAuth != "" {
		req.Header.Set("Authorization", r.ntfyAuth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	connected()
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		var m Message
		if json.Unmarshal(sc.Bytes(), &m) != nil || m.Event != "message" {
			continue
		}
		r.deliver(m, append([]byte(nil), sc.Bytes()...))
		r.update(func(s *state) { s.LastID = m.ID })
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return errors.New("closed")
}

// MARK: delivery

type Message struct {
	ID       string `json:"id"`
	Event    string `json:"event"`
	Topic    string `json:"topic"`
	Title    string `json:"title"`
	Message  string `json:"message"`
	Priority int    `json:"priority"`
}

const e2ePrefix = "pling:e2e:v1:"

func (r *Relay) deliver(m Message, raw []byte) {
	r.mu.Lock()
	type target struct {
		token string
		d     Device
	}
	var targets []target
	for token, d := range r.st.Devices {
		if wants(d, m, time.Now()) {
			targets = append(targets, target{token, d})
		}
	}
	r.mu.Unlock()
	for _, t := range targets {
		err := r.apns.Send(t.token, t.d.Sandbox, m, Payload(m, raw, t.d.Server))
		if errors.Is(err, errGone) {
			log.Printf("dropping device %s…", t.token[:8])
			r.update(func(s *state) { delete(s.Devices, t.token) })
		} else if err != nil {
			log.Printf("push %s to %s…: %v", m.ID, t.token[:8], err)
		}
	}
}

func wants(d Device, m Message, now time.Time) bool {
	p := m.Priority
	if p == 0 {
		p = 3
	}
	for _, t := range d.Topics {
		if t.Topic == m.Topic {
			return p >= t.MinPriority && (t.MutedUntil == 0 || now.Unix() >= t.MutedUntil)
		}
	}
	return false
}

// Payload is what the device receives. "m" is the raw ntfy message for the extension;
// the alert is a readable fallback if the extension doesn't run. Never shows ciphertext.
func Payload(m Message, raw []byte, server string) []byte {
	p := m.Priority
	if p == 0 {
		p = 3
	}
	title, body := m.Title, m.Message
	if strings.HasPrefix(body, e2ePrefix) {
		title, body = "🔒 Encrypted message", "Open Pling to read it."
	}
	if title == "" {
		title = m.Topic
	}
	aps := map[string]any{
		"alert":           map[string]string{"title": title, "body": truncate(body, 1000)},
		"mutable-content": 1,
		"thread-id":       m.Topic,
	}
	switch {
	case p <= 2:
		aps["interruption-level"] = "passive"
	case p >= 4:
		aps["interruption-level"] = "time-sensitive"
		aps["sound"] = "default"
	default:
		aps["sound"] = "default"
	}
	out, _ := json.Marshal(map[string]any{"aps": aps, "s": server, "m": json.RawMessage(raw)})
	if len(out) > 4096 { // APNs limit; the app fetches the full message when opened
		out, _ = json.Marshal(map[string]any{"aps": aps, "s": server})
	}
	return out
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8Start(s[n]) {
		n--
	}
	return s[:n] + "…"
}

func utf8Start(b byte) bool { return b&0xC0 != 0x80 }

// MARK: APNs

var errGone = errors.New("device token no longer valid")

type APNs struct {
	key         *ecdsa.PrivateKey
	keyID, team string
	topic       string
	client      *http.Client
	mu          sync.Mutex
	jwt         string
	jwtIssuedAt time.Time
}

func NewAPNs(keyFile, keyID, team, topic string) (*APNs, error) {
	b, err := os.ReadFile(keyFile)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(b)
	if block == nil {
		return nil, errors.New("APNs key: not PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("APNs key: not an EC key")
	}
	return &APNs{key: ec, keyID: keyID, team: team, topic: topic, client: &http.Client{Timeout: 15 * time.Second}}, nil
}

// token returns a provider JWT, reused for 50 minutes (Apple rejects tokens older than an hour).
func (a *APNs) token() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.jwt != "" && time.Since(a.jwtIssuedAt) < 50*time.Minute {
		return a.jwt, nil
	}
	enc := base64.RawURLEncoding
	head, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.keyID})
	now := time.Now()
	claims, _ := json.Marshal(map[string]any{"iss": a.team, "iat": now.Unix()})
	unsigned := enc.EncodeToString(head) + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(unsigned))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, sum[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	a.jwt, a.jwtIssuedAt = unsigned+"."+enc.EncodeToString(sig), now
	return a.jwt, nil
}

func (a *APNs) Send(deviceToken string, sandbox bool, m Message, payload []byte) error {
	host := "https://api.push.apple.com"
	if sandbox {
		host = "https://api.sandbox.push.apple.com"
	}
	jwt, err := a.token()
	if err != nil {
		return err
	}
	req, _ := http.NewRequest("POST", host+"/3/device/"+deviceToken, bytes.NewReader(payload))
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-topic", a.topic)
	req.Header.Set("apns-collapse-id", m.ID)
	req.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(24*time.Hour).Unix()))
	if m.Priority != 0 && m.Priority <= 2 {
		req.Header.Set("apns-priority", "5")
	} else {
		req.Header.Set("apns-priority", "10")
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 200 {
		return nil
	}
	var reason struct{ Reason string }
	json.NewDecoder(resp.Body).Decode(&reason)
	if resp.StatusCode == 410 || reason.Reason == "BadDeviceToken" || reason.Reason == "DeviceTokenNotForTopic" {
		return errGone
	}
	if reason.Reason == "ExpiredProviderToken" {
		a.mu.Lock()
		a.jwt = ""
		a.mu.Unlock()
	}
	return fmt.Errorf("APNs %d %s", resp.StatusCode, reason.Reason)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func must(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("%s is required", k)
	}
	return v
}
