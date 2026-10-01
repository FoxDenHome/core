package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/fastly"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/registry"
	"github.com/FoxDenHome/core/vpn/internal/routeros"
	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

const (
	cookieSession = "fvp_session"
	cookieLogin   = "fvp_login"
	sessionTTL    = 12 * time.Hour
)

//go:embed templates/*.html
var templateFS embed.FS

var pages = template.Must(template.ParseFS(templateFS, "templates/*.html"))

var userName = regexp.MustCompile(`^[a-z0-9][a-z0-9_.-]{0,31}$`)

// conn is a RouterOS API connection; an interface so tests can fake routers.
type conn interface {
	registry.API
	Close() error
}

func dialRouter(ctx context.Context, r routeros.Router) (conn, error) { return r.Dial(ctx) }

type portal struct {
	cfg     Config
	dial    func(context.Context, routeros.Router) (conn, error)
	cookies *signer
	dict    *fastly.Dictionary

	oidcMu   sync.Mutex
	oauth    *oauth2.Config
	verifier *oidc.IDTokenVerifier

	// mu serializes changes, so two requests never pick the same address.
	mu sync.Mutex

	// status holds the latest sync outcome per peer public key. It is only in
	// memory: after a restart it is pending until the first reconcile.
	statusMu sync.Mutex
	status   map[string]peerStatus
}

// targetStatus is where one sync target stands for one peer.
type targetStatus struct {
	Target string
	OK     bool
	Detail string
}

type peerStatus struct {
	Targets []targetStatus
	At      time.Time
}

func (s peerStatus) OK() bool {
	for _, t := range s.Targets {
		if !t.OK {
			return false
		}
	}
	return true
}

// targetName shortens a router address to its host label, e.g. "router-backup".
func targetName(r routeros.Router) string {
	host := r.Address
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if label, _, ok := strings.Cut(host, "."); ok && net.ParseIP(host) == nil {
		return label
	}
	return host
}

func (p *portal) setupOIDC(ctx context.Context) error {
	p.oidcMu.Lock()
	defer p.oidcMu.Unlock()
	if p.oauth != nil {
		return nil
	}
	provider, err := oidc.NewProvider(ctx, p.cfg.OIDC.Issuer)
	if err != nil {
		return err
	}
	p.verifier = provider.Verifier(&oidc.Config{ClientID: p.cfg.OIDC.ClientID})
	p.oauth = &oauth2.Config{
		ClientID:    p.cfg.OIDC.ClientID,
		Endpoint:    provider.Endpoint(),
		RedirectURL: strings.TrimSuffix(p.cfg.PublicURL, "/") + "/oauth2/callback",
		Scopes:      []string{oidc.ScopeOpenID, "profile"},
	}
	return nil
}

func (p *portal) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", p.index)
	mux.HandleFunc("POST /devices", p.withSession(p.upsertDevice))
	mux.HandleFunc("POST /devices/delete", p.withSession(p.deleteDevice))
	mux.HandleFunc("GET /enroll", p.enrollPage)
	mux.HandleFunc("POST /enroll", p.withSession(p.enrollSubmit))
	mux.HandleFunc("POST /api/enroll/complete", p.enrollComplete)
	mux.HandleFunc("GET /login", p.login)
	mux.HandleFunc("GET /oauth2/callback", p.callback)
	mux.HandleFunc("POST /logout", func(w http.ResponseWriter, r *http.Request) {
		p.cookies.clear(w, cookieSession)
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	return securityHeaders(mux)
}

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		h.ServeHTTP(w, r)
	})
}

func (p *portal) session(r *http.Request) *session {
	var s session
	if p.cookies.get(r, cookieSession, &s) != nil || time.Now().After(s.Expires) {
		return nil
	}
	return &s
}

// withSession guards a form post: it needs a session and a matching CSRF token.
func (p *portal) withSession(h func(http.ResponseWriter, *http.Request, *session)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s := p.session(r)
		if s == nil {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		if r.PostFormValue("csrf") != p.cookies.csrf(s) {
			http.Error(w, "invalid form token, please reload the page", http.StatusForbidden)
			return
		}
		h(w, r, s)
	}
}

func randomString() string {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func (p *portal) login(w http.ResponseWriter, r *http.Request) {
	if err := p.setupOIDC(r.Context()); err != nil {
		http.Error(w, "Login is unavailable right now (cannot reach Kanidm). Existing VPN devices keep working.", http.StatusServiceUnavailable)
		return
	}
	next := r.URL.Query().Get("next")
	if !strings.HasPrefix(next, "/") || strings.HasPrefix(next, "//") {
		next = "/"
	}
	st := loginState{State: randomString(), Verifier: oauth2.GenerateVerifier(), Next: next, Expires: time.Now().Add(10 * time.Minute)}
	if err := p.cookies.set(w, cookieLogin, st, 10*time.Minute); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, p.oauth.AuthCodeURL(st.State, oauth2.S256ChallengeOption(st.Verifier)), http.StatusFound)
}

func (p *portal) callback(w http.ResponseWriter, r *http.Request) {
	var st loginState
	if err := p.cookies.get(r, cookieLogin, &st); err != nil || time.Now().After(st.Expires) ||
		r.URL.Query().Get("state") != st.State {
		http.Error(w, "login expired, please try again", http.StatusBadRequest)
		return
	}
	p.cookies.clear(w, cookieLogin)
	if e := r.URL.Query().Get("error"); e != "" {
		http.Error(w, "login failed: "+e, http.StatusForbidden)
		return
	}
	if err := p.setupOIDC(r.Context()); err != nil {
		http.Error(w, "cannot reach Kanidm", http.StatusServiceUnavailable)
		return
	}
	tok, err := p.oauth.Exchange(r.Context(), r.URL.Query().Get("code"), oauth2.VerifierOption(st.Verifier))
	if err != nil {
		http.Error(w, "login failed: "+err.Error(), http.StatusForbidden)
		return
	}
	raw, _ := tok.Extra("id_token").(string)
	idt, err := p.verifier.Verify(r.Context(), raw)
	if err != nil {
		http.Error(w, "login failed: "+err.Error(), http.StatusForbidden)
		return
	}
	var claims struct {
		PreferredUsername string `json:"preferred_username"`
	}
	if err := idt.Claims(&claims); err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	// Kanidm's preferred_username may be the SPN (user@domain).
	user, _, _ := strings.Cut(strings.ToLower(claims.PreferredUsername), "@")
	if !userName.MatchString(user) {
		http.Error(w, fmt.Sprintf("unsupported user name %q", claims.PreferredUsername), http.StatusForbidden)
		return
	}
	sess := session{User: user, Expires: time.Now().Add(sessionTTL)}
	if err := p.cookies.set(w, cookieSession, sess, sessionTTL); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("login: %s", user)
	http.Redirect(w, r, st.Next, http.StatusSeeOther)
}

type deviceView struct {
	Name          string
	PublicKey     string
	Addresses     []string
	LastHandshake string
	Disabled      bool
	// Sync is nil while no reconcile has covered this device yet.
	Sync    []targetStatus
	SyncOK  bool
	SyncAge string
}

// ago renders a short "how long ago" for the status tooltip.
func ago(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < 10*time.Second:
		return "just now"
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	default:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
}

func (p *portal) index(w http.ResponseWriter, r *http.Request) {
	s := p.session(r)
	if s == nil {
		http.Redirect(w, r, "/login?next="+url.QueryEscape(r.URL.RequestURI()), http.StatusSeeOther)
		return
	}
	q := r.URL.Query()
	data := map[string]any{
		"User":    s.User,
		"CSRF":    p.cookies.csrf(s),
		"Name":    q.Get("name"),
		"Key":     q.Get("pubkey"),
		"Message": q.Get("msg"),
		"Error":   q.Get("err"),
	}
	snap, err := p.readPrimary(r.Context())
	if err != nil {
		log.Printf("reading devices: %v", err)
		data["Error"] = "Cannot reach the router right now: " + err.Error()
	} else {
		var devices []deviceView
		for _, peer := range snap.OwnedBy(s.User) {
			v := deviceView{Name: peer.Device(), PublicKey: peer.PublicKey, LastHandshake: peer.LastHandshake, Disabled: peer.Disabled}
			for _, a := range peer.Addresses {
				v.Addresses = append(v.Addresses, a.Addr().String())
			}
			if st, ok := p.peerStatus(peer.PublicKey); ok {
				v.Sync, v.SyncOK, v.SyncAge = st.Targets, st.OK(), ago(st.At)
			}
			devices = append(devices, v)
			if v.PublicKey == data["Key"] && data["Name"] == "" {
				data["Name"] = v.Name
			}
		}
		data["Devices"] = devices
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := pages.ExecuteTemplate(w, "index.html", data); err != nil {
		log.Printf("render: %v", err)
	}
}

func redirectWith(w http.ResponseWriter, r *http.Request, key, msg string) {
	http.Redirect(w, r, "/?"+key+"="+url.QueryEscape(msg), http.StatusSeeOther)
}

func (p *portal) upsertDevice(w http.ResponseWriter, r *http.Request, s *session) {
	device := strings.ToLower(strings.TrimSpace(r.PostFormValue("name")))
	key := strings.TrimSpace(r.PostFormValue("pubkey"))

	p.mu.Lock()
	defer p.mu.Unlock()
	msg, err := p.change(r.Context(), func(ctx context.Context, c registry.API, snap *registry.Snapshot) (string, error) {
		id, attrs, err := snap.Upsert(p.cfg.VPN, s.User, device, key)
		if err != nil {
			return "", err
		}
		if err := registry.Apply(ctx, c, id, attrs); err != nil {
			return "", err
		}
		if id == "" {
			log.Printf("%s registered device %s (%s)", s.User, device, attrs["allowed-address"])
			return fmt.Sprintf("Registered %s as %s.", device, attrs["allowed-address"]), nil
		}
		log.Printf("%s replaced the key of device %s", s.User, device)
		return fmt.Sprintf("Replaced the key of %s.", device), nil
	})
	if err != nil {
		redirectWith(w, r, "err", err.Error())
		return
	}
	redirectWith(w, r, "msg", msg+" The device picks up its configuration within a few minutes.")
}

func (p *portal) deleteDevice(w http.ResponseWriter, r *http.Request, s *session) {
	device := r.PostFormValue("name")

	p.mu.Lock()
	defer p.mu.Unlock()
	msg, err := p.change(r.Context(), func(ctx context.Context, c registry.API, snap *registry.Snapshot) (string, error) {
		peer := snap.ByName(registry.PeerName(s.User, device))
		if peer == nil || peer.Owner != s.User {
			return "", errors.New("no such device")
		}
		if err := registry.Remove(ctx, c, peer.ID); err != nil {
			return "", err
		}
		log.Printf("%s removed device %s", s.User, device)
		return "Removed " + device + ".", nil
	})
	if err != nil {
		redirectWith(w, r, "err", err.Error())
		return
	}
	redirectWith(w, r, "msg", msg)
}

// change applies fn to the primary router, then mirrors and publishes. Only
// the primary write has to succeed; the reconcile loop repairs the rest.
func (p *portal) change(ctx context.Context, fn func(context.Context, registry.API, *registry.Snapshot) (string, error)) (string, error) {
	c, err := p.dial(ctx, p.cfg.Routers[0])
	if err != nil {
		return "", err
	}
	defer c.Close()
	snap, err := registry.Read(ctx, c, p.cfg.VPN)
	if err != nil {
		return "", err
	}
	msg, err := fn(ctx, c, snap)
	if err != nil {
		return "", err
	}
	if err := p.syncFrom(ctx, c); err != nil {
		log.Printf("sync after change: %v", err)
		msg += " (Some routers or the CDN could not be updated yet; this is retried automatically.)"
	}
	return msg, nil
}

func (p *portal) readPrimary(ctx context.Context) (*registry.Snapshot, error) {
	c, err := p.dial(ctx, p.cfg.Routers[0])
	if err != nil {
		return nil, err
	}
	defer c.Close()
	return registry.Read(ctx, c, p.cfg.VPN)
}

func (p *portal) reconcileLoop(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		p.mu.Lock()
		c, err := p.dial(ctx, p.cfg.Routers[0])
		if err == nil {
			err = p.syncFrom(ctx, c)
			c.Close()
		}
		p.mu.Unlock()
		if err != nil {
			log.Printf("reconcile: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// syncFrom mirrors the primary's peers to the other routers and publishes
// provisioning for all of them, recording the outcome per peer.
func (p *portal) syncFrom(ctx context.Context, primary registry.API) error {
	snap, err := registry.Read(ctx, primary, p.cfg.VPN)
	if err != nil {
		return err
	}
	results := map[string][]targetStatus{}
	record := func(key string, target string, err error, okDetail string) {
		ts := targetStatus{Target: target, OK: err == nil, Detail: okDetail}
		if err != nil {
			ts.Detail = err.Error()
		}
		results[key] = append(results[key], ts)
	}
	for _, peer := range snap.Peers {
		record(peer.PublicKey, targetName(p.cfg.Routers[0]), nil, "source of truth")
	}

	var errs []error
	for _, r := range p.cfg.Routers[1:] {
		name := targetName(r)
		var perPeer map[string]error
		c, err := p.dial(ctx, r)
		if err == nil {
			perPeer, err = registry.Mirror(ctx, c, p.cfg.VPN, snap)
			c.Close()
		}
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", r.Address, err))
		}
		for _, peer := range snap.Peers {
			perr, done := perPeer[peer.PublicKey]
			switch {
			case perr != nil:
				errs = append(errs, fmt.Errorf("%s: %s: %w", r.Address, peer.Name, perr))
				record(peer.PublicKey, name, perr, "")
			case !done && err != nil:
				record(peer.PublicKey, name, err, "")
			default:
				record(peer.PublicKey, name, nil, "in sync")
			}
		}
	}

	perPeer, err := p.publish(ctx, snap)
	if err != nil {
		errs = append(errs, err)
	}
	for _, peer := range snap.Peers {
		ts, ok := perPeer[peer.PublicKey]
		if !ok {
			ts = targetStatus{OK: false, Detail: "not published"}
			if err != nil {
				ts.Detail = err.Error()
			}
		}
		ts.Target = "Fastly"
		if !ts.OK {
			errs = append(errs, fmt.Errorf("fastly: %s: %s", peer.Name, ts.Detail))
		}
		results[peer.PublicKey] = append(results[peer.PublicKey], ts)
	}

	now := time.Now()
	status := make(map[string]peerStatus, len(results))
	for key, targets := range results {
		status[key] = peerStatus{Targets: targets, At: now}
	}
	p.statusMu.Lock()
	p.status = status
	p.statusMu.Unlock()
	return errors.Join(errs...)
}

func (p *portal) peerStatus(key string) (peerStatus, bool) {
	p.statusMu.Lock()
	defer p.statusMu.Unlock()
	s, ok := p.status[key]
	return s, ok
}

// publish makes the CDN dictionary hold exactly one current blob per peer.
// It returns the outcome per peer public key, plus any error not tied to one.
func (p *portal) publish(ctx context.Context, snap *registry.Snapshot) (map[string]targetStatus, error) {
	if p.dict == nil {
		return nil, errors.New("not configured (FASTLY_API_TOKEN is not set)")
	}
	serverKey, err := wgtypes.ParseKey(snap.Server["private-key"])
	if err != nil {
		return nil, fmt.Errorf("reading %s private key (does the API user have the sensitive policy?): %w", p.cfg.VPN.Interface, err)
	}
	items, err := p.dict.Items(ctx)
	if err != nil {
		return nil, err
	}

	results := map[string]targetStatus{}
	wanted := map[string]bool{}
	for _, peer := range snap.Peers {
		cfg := snap.Config(peer, p.cfg.VPN)
		pub, err := wgtypes.ParseKey(peer.PublicKey)
		if err != nil {
			results[peer.PublicKey] = targetStatus{Detail: "invalid public key"}
			continue
		}
		if cfg == nil {
			results[peer.PublicKey] = targetStatus{OK: true, Detail: "nothing to publish (disabled or no address)"}
			continue
		}
		key := p.cfg.Fastly.KeyPrefix + provision.BlobName(pub)
		wanted[key] = true

		if cur, ok := items[key]; ok {
			if blob, err := base64.StdEncoding.DecodeString(cur); err == nil {
				if old, err := provision.OpenAsServer(blob, serverKey, pub); err == nil && sameJSON(old, cfg) {
					// Sealing is randomized, so compare contents.
					results[peer.PublicKey] = targetStatus{OK: true, Detail: "published"}
					continue
				}
			}
		}
		blob, err := provision.Seal(cfg, serverKey, pub)
		if err == nil {
			err = p.dict.Put(ctx, key, base64.StdEncoding.EncodeToString(blob))
		}
		if err != nil {
			results[peer.PublicKey] = targetStatus{Detail: err.Error()}
			continue
		}
		results[peer.PublicKey] = targetStatus{OK: true, Detail: "published"}
		log.Printf("published provisioning for %s", peer.Name)
	}

	var errs []error
	for key := range items {
		if strings.HasPrefix(key, p.cfg.Fastly.KeyPrefix) && !wanted[key] {
			if err := p.dict.Delete(ctx, key); err != nil {
				errs = append(errs, fmt.Errorf("withdrawing %s: %w", key, err))
			} else {
				log.Printf("withdrew provisioning %s", key)
			}
		}
	}
	return results, errors.Join(errs...)
}

func sameJSON(a, b any) bool {
	ja, err1 := json.Marshal(a)
	jb, err2 := json.Marshal(b)
	return err1 == nil && err2 == nil && bytes.Equal(ja, jb)
}
