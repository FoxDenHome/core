package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"html"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/fastly"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/registry/registrytest"
	"github.com/FoxDenHome/core/vpn/internal/routeros"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// fakeFastly implements the few dictionary endpoints the portal uses.
type fakeFastly struct {
	mu    sync.Mutex
	items map[string]string
}

func (f *fakeFastly) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	p := r.URL.Path
	switch {
	case strings.HasSuffix(p, "/details"):
		_, _ = w.Write([]byte(`{"id": "svc", "active_version": {"number": 3, "active": true}}`))
	case strings.Contains(p, "/version/3/dictionary/vpn_peers"):
		_, _ = w.Write([]byte(`{"id": "dict1"}`))
	case strings.HasSuffix(p, "/dictionary/dict1/items"):
		var out []map[string]string
		for k, v := range f.items {
			out = append(out, map[string]string{"item_key": k, "item_value": v})
		}
		_ = json.NewEncoder(w).Encode(out)
	case strings.Contains(p, "/dictionary/dict1/item/"):
		key, _ := url.PathUnescape(strings.SplitN(r.URL.EscapedPath(), "/item/", 2)[1])
		switch r.Method {
		case http.MethodPut:
			_ = r.ParseForm()
			f.items[key] = r.PostForm.Get("item_value")
		case http.MethodDelete:
			delete(f.items, key)
		}
		_, _ = w.Write([]byte(`{}`))
	default:
		http.NotFound(w, r)
	}
}

type harness struct {
	t       *testing.T
	p       *portal
	srv     *httptest.Server
	primary *registrytest.Router
	backup  *registrytest.Router
	cdn     *fakeFastly
}

func newHarness(t *testing.T) *harness {
	h := &harness{t: t, primary: registrytest.New(), backup: registrytest.New(), cdn: &fakeFastly{items: map[string]string{}}}
	// Both routers share the wg-vpn key, like router and router-backup.
	h.backup.Tables["/interface/wireguard"] = h.primary.Tables["/interface/wireguard"]
	fastlySrv := httptest.NewServer(h.cdn)
	t.Cleanup(fastlySrv.Close)

	cfg := defaultConfig()
	cfg.Routers = []routeros.Router{{Address: "primary"}, {Address: "backup"}}
	cfg.Fastly.ServiceID = "svc"
	h.p = &portal{
		cfg:     cfg,
		cookies: &signer{key: []byte("test")},
		dict:    &fastly.Dictionary{BaseURL: fastlySrv.URL, ServiceID: "svc", Name: "vpn_peers"},
		dial: func(_ context.Context, r routeros.Router) (conn, error) {
			if r.Address == "primary" {
				return h.primary, nil
			}
			return h.backup, nil
		},
	}
	h.srv = httptest.NewServer(h.p.routes())
	t.Cleanup(h.srv.Close)
	return h
}

func (h *harness) client(user string) (*http.Client, string) {
	sess := session{User: user, Expires: time.Now().Add(time.Hour).Truncate(time.Second)}
	rec := httptest.NewRecorder()
	if err := h.p.cookies.set(rec, cookieSession, sess, time.Hour); err != nil {
		h.t.Fatal(err)
	}
	jar := &simpleJar{cookies: rec.Result().Cookies()}
	c := &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return c, h.p.cookies.csrf(&sess)
}

type simpleJar struct{ cookies []*http.Cookie }

func (j *simpleJar) SetCookies(*url.URL, []*http.Cookie) {}
func (j *simpleJar) Cookies(*url.URL) []*http.Cookie     { return j.cookies }

func (h *harness) post(c *http.Client, path string, form url.Values) *http.Response {
	h.t.Helper()
	resp, err := c.PostForm(h.srv.URL+path, form)
	if err != nil {
		h.t.Fatal(err)
	}
	resp.Body.Close()
	return resp
}

func flash(resp *http.Response) (string, string) {
	u, _ := url.Parse(resp.Header.Get("Location"))
	return u.Query().Get("msg"), u.Query().Get("err")
}

func (h *harness) blobFor(priv wgtypes.Key) *provision.Config {
	h.t.Helper()
	h.cdn.mu.Lock()
	v, ok := h.cdn.items["/vpn/peers/"+provision.BlobName(priv.PublicKey())]
	h.cdn.mu.Unlock()
	if !ok {
		return nil
	}
	blob, _ := base64.StdEncoding.DecodeString(v)
	server, _ := wgtypes.ParseKey(h.primary.Tables["/interface/wireguard"][0]["public-key"])
	cfg, err := provision.Open(blob, priv, server)
	if err != nil {
		h.t.Fatalf("published blob does not open for its device: %v", err)
	}
	return cfg
}

func peerNames(r *registrytest.Router) []string {
	var out []string
	for _, row := range r.Tables["/interface/wireguard/peers"] {
		out = append(out, row["name"])
	}
	return out
}

func TestRegisterOverwriteDelete(t *testing.T) {
	h := newHarness(t)
	c, csrf := h.client("dori")
	dev1, _ := wgtypes.GeneratePrivateKey()

	resp := h.post(c, "/devices", url.Values{"csrf": {csrf}, "name": {"laptop"}, "pubkey": {dev1.PublicKey().String()}})
	if msg, errMsg := flash(resp); errMsg != "" || !strings.Contains(msg, "10.100.10.1/32") || strings.Contains(msg, "could not be updated") {
		t.Fatalf("register: msg=%q err=%q", msg, errMsg)
	}
	cfg := h.blobFor(dev1)
	if cfg == nil || cfg.Name != "dori-laptop" || cfg.Addresses[0].String() != "10.100.10.1/32" {
		t.Fatalf("provisioning not published correctly: %+v", cfg)
	}
	if got := peerNames(h.backup); len(got) != 1 || got[0] != "dori-laptop" {
		t.Fatalf("backup router not mirrored: %v", got)
	}

	// Reinstalled laptop: same name, new key, same address; old blob withdrawn.
	dev2, _ := wgtypes.GeneratePrivateKey()
	resp = h.post(c, "/devices", url.Values{"csrf": {csrf}, "name": {"laptop"}, "pubkey": {dev2.PublicKey().String()}})
	if _, errMsg := flash(resp); errMsg != "" {
		t.Fatal(errMsg)
	}
	if h.blobFor(dev1) != nil {
		t.Fatal("old key's provisioning is still published")
	}
	if rows := h.backup.Tables["/interface/wireguard/peers"]; len(rows) != 1 || rows[0]["public-key"] != dev2.PublicKey().String() {
		t.Fatalf("backup router did not get the new key: %v", rows)
	}
	if cfg := h.blobFor(dev2); cfg == nil || cfg.Addresses[0].String() != "10.100.10.1/32" {
		t.Fatalf("overwrite did not keep the address: %+v", cfg)
	}

	// Another user can neither take the key nor see or delete the device.
	c2, csrf2 := h.client("wizzy")
	resp = h.post(c2, "/devices", url.Values{"csrf": {csrf2}, "name": {"laptop"}, "pubkey": {dev2.PublicKey().String()}})
	if _, errMsg := flash(resp); !strings.Contains(errMsg, "someone else") {
		t.Fatalf("key theft not rejected: %q", errMsg)
	}
	resp = h.post(c2, "/devices/delete", url.Values{"csrf": {csrf2}, "name": {"laptop"}})
	if _, errMsg := flash(resp); errMsg == "" {
		t.Fatal("deleting another user's device was allowed")
	}

	resp = h.post(c, "/devices/delete", url.Values{"csrf": {csrf}, "name": {"laptop"}})
	if _, errMsg := flash(resp); errMsg != "" {
		t.Fatal(errMsg)
	}
	if len(peerNames(h.primary)) != 0 || len(peerNames(h.backup)) != 0 || h.blobFor(dev2) != nil {
		t.Fatal("delete did not propagate")
	}
}

func TestRequiresSessionAndCSRF(t *testing.T) {
	h := newHarness(t)
	anon := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := anon.Get(h.srv.URL + "/?pubkey=abc")
	if err != nil {
		t.Fatal(err)
	}
	if loc := resp.Header.Get("Location"); !strings.HasPrefix(loc, "/login?next=") {
		t.Fatalf("anonymous index: %d %q", resp.StatusCode, loc)
	}
	if resp := h.post(anon, "/devices", url.Values{"name": {"x"}}); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("anonymous post: %d", resp.StatusCode)
	}

	c, _ := h.client("dori")
	if resp := h.post(c, "/devices", url.Values{"csrf": {"forged"}, "name": {"x"}}); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("forged csrf: %d", resp.StatusCode)
	}
	if len(peerNames(h.primary)) != 0 {
		t.Fatal("rejected request still changed the router")
	}
}

func TestIndexPrefillsFromTray(t *testing.T) {
	h := newHarness(t)
	c, _ := h.client("dori")
	key, _ := wgtypes.GeneratePrivateKey()
	resp, err := c.Get(h.srv.URL + "/?name=laptop&pubkey=" + url.QueryEscape(key.PublicKey().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body strings.Builder
	buf := make([]byte, 1<<16)
	for {
		n, err := resp.Body.Read(buf)
		body.Write(buf[:n])
		if err != nil {
			break
		}
	}
	page := html.UnescapeString(body.String())
	if !strings.Contains(page, `value="laptop"`) || !strings.Contains(page, `value="`+key.PublicKey().String()+`"`) {
		t.Fatalf("form not prefilled: %s", page)
	}
}

// failingRouter rejects every write, like a router-backup that is out of reach
// for changes.
type failingRouter struct{ *registrytest.Router }

func (f failingRouter) Add(context.Context, string, routeros.Row) error {
	return errors.New("failure: simulated")
}

func TestSyncStatus(t *testing.T) {
	h := newHarness(t)
	c, csrf := h.client("dori")
	dev, _ := wgtypes.GeneratePrivateKey()
	key := dev.PublicKey().String()

	if _, ok := h.p.peerStatus(key); ok {
		t.Fatal("status before any sync")
	}
	h.post(c, "/devices", url.Values{"csrf": {csrf}, "name": {"laptop"}, "pubkey": {key}})
	st, ok := h.p.peerStatus(key)
	if !ok || !st.OK() {
		t.Fatalf("status after register: %+v", st)
	}
	var names []string
	for _, ts := range st.Targets {
		names = append(names, ts.Target)
	}
	if strings.Join(names, ",") != "primary,backup,Fastly" {
		t.Fatalf("targets = %v", names)
	}

	// Backup refuses writes: only its entry turns bad, and the page says so.
	backup := h.backup
	h.p.dial = func(_ context.Context, r routeros.Router) (conn, error) {
		if r.Address == "primary" {
			return h.primary, nil
		}
		return failingRouter{backup}, nil
	}
	dev2, _ := wgtypes.GeneratePrivateKey()
	h.post(c, "/devices", url.Values{"csrf": {csrf}, "name": {"phone"}, "pubkey": {dev2.PublicKey().String()}})
	st, _ = h.p.peerStatus(dev2.PublicKey().String())
	if st.OK() || st.Targets[0].OK != true || st.Targets[1].OK || !strings.Contains(st.Targets[1].Detail, "simulated") || !st.Targets[2].OK {
		t.Fatalf("status with failing backup: %+v", st)
	}
	if st, _ := h.p.peerStatus(key); !st.OK() {
		t.Fatalf("unaffected device turned bad: %+v", st)
	}

	resp, err := c.Get(h.srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	page := html.UnescapeString(string(body))
	if !strings.Contains(page, "Sync status: everything done") || !strings.Contains(page, "Sync status: something is wrong") ||
		!strings.Contains(page, "failure: simulated") {
		t.Fatal("status icons not rendered")
	}
}

func TestTargetName(t *testing.T) {
	for in, want := range map[string]string{
		"router.foxden.network:8728":        "router",
		"router-backup.foxden.network:8728": "router-backup",
		"10.2.1.1:8728":                     "10.2.1.1",
		"[fd2c:f4cb:63be:2::101]:8728":      "fd2c:f4cb:63be:2::101",
	} {
		if got := targetName(routeros.Router{Address: in}); got != want {
			t.Errorf("targetName(%q) = %q, want %q", in, got, want)
		}
	}
}
