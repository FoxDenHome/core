// krb5-sync sets a user's Kerberos key from their kanidm unix password.
//
// Kanidm only stores a one-way hash of the unix password, so the KDC can't
// derive keys from it. Instead, whenever someone proves the password to us,
// we check it against kanidm and push it to the KDC via kadmin.
//
// Two ways in:
//   - GET/POST /         browser form, user identity from the trusted header
//     set by nginx after oauth2-proxy
//   - POST /api/sync     username+password form, for PAM hooks on clients
package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

var (
	listenAddr    = flag.String("listen", "127.0.0.1:8088", "HTTP listen address")
	kanidmURL     = flag.String("kanidm-url", "https://auth.foxden.network", "kanidm base URL")
	realm         = flag.String("realm", "FOXDEN.NETWORK", "Kerberos realm")
	usersFile     = flag.String("users-file", "", "file with one allowed username per line")
	kadminPath    = flag.String("kadmin", "kadmin", "path to the MIT kadmin binary")
	keytabPath    = flag.String("keytab", "", "keytab for the admin principal")
	adminPrinc    = flag.String("principal", "krb5-sync", "admin principal (without realm)")
	userHeader    = flag.String("user-header", "X-Preferred-Username", "header carrying the authenticated username")
	realIPHeader  = flag.String("real-ip-header", "X-Real-IP", "header carrying the client IP")
	nasHostname   = flag.String("smb-host", "nas.foxden.network", "SMB server shown in the instructions")
	failWindow    = 15 * time.Minute
	failThreshold = 5
)

// Usernames go into a kadmin query string, so keep them boring.
var usernameRe = regexp.MustCompile(`^[a-z_][a-z0-9_.-]{0,63}$`)

var (
	errBadCredentials = errors.New("invalid username or password")
	errNotAllowed     = errors.New("user is not enabled for Kerberos")
	errRateLimited    = errors.New("too many failed attempts, try again later")
)

type server struct {
	csrfKey []byte
	client  *http.Client

	mu       sync.Mutex
	failures map[string][]time.Time
}

func main() {
	flag.Parse()
	if *usersFile == "" || *keytabPath == "" {
		log.Fatal("-users-file and -keytab are required")
	}

	s := &server{
		csrfKey:  make([]byte, 32),
		client:   &http.Client{Timeout: 15 * time.Second},
		failures: map[string][]time.Time{},
	}
	if _, err := rand.Read(s.csrfKey); err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("POST /{$}", s.handleIndexPost)
	mux.HandleFunc("POST /api/sync", s.handleAPISync)

	srv := &http.Server{
		Addr:              *listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("listening on %s", *listenAddr)
	log.Fatal(srv.ListenAndServe())
}

func (s *server) csrfToken(user string) string {
	mac := hmac.New(sha256.New, s.csrfKey)
	mac.Write([]byte(user))
	return hex.EncodeToString(mac.Sum(nil))
}

func (s *server) webUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	user := r.Header.Get(*userHeader)
	if !usernameRe.MatchString(user) {
		http.Error(w, "not authenticated", http.StatusForbidden)
		return "", false
	}
	return user, true
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	user, ok := s.webUser(w, r)
	if !ok {
		return
	}
	s.render(w, http.StatusOK, pageData{User: user, CSRF: s.csrfToken(user)})
}

func (s *server) handleIndexPost(w http.ResponseWriter, r *http.Request) {
	user, ok := s.webUser(w, r)
	if !ok {
		return
	}
	data := pageData{User: user, CSRF: s.csrfToken(user)}

	if !hmac.Equal([]byte(r.PostFormValue("csrf")), []byte(data.CSRF)) {
		http.Error(w, "bad CSRF token, reload the page", http.StatusBadRequest)
		return
	}

	err := s.sync(r.Context(), user, r.PostFormValue("password"), clientIP(r))
	status := http.StatusOK
	if err != nil {
		data.Error = err.Error()
		status = statusFor(err)
	} else {
		data.Success = true
	}
	s.render(w, status, data)
}

func (s *server) handleAPISync(w http.ResponseWriter, r *http.Request) {
	user := r.PostFormValue("username")
	// pam_exec's expose_authtok NUL-terminates the password
	password := strings.TrimRight(r.PostFormValue("password"), "\x00\r\n")

	err := s.sync(r.Context(), user, password, clientIP(r))
	if err != nil {
		http.Error(w, err.Error(), statusFor(err))
		return
	}
	fmt.Fprintln(w, "ok")
}

func statusFor(err error) int {
	switch {
	case errors.Is(err, errBadCredentials):
		return http.StatusUnauthorized
	case errors.Is(err, errNotAllowed):
		return http.StatusForbidden
	case errors.Is(err, errRateLimited):
		return http.StatusTooManyRequests
	default:
		return http.StatusInternalServerError
	}
}

func clientIP(r *http.Request) string {
	if ip := r.Header.Get(*realIPHeader); ip != "" {
		return ip
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

func (s *server) sync(ctx context.Context, user, password, ip string) error {
	if !usernameRe.MatchString(user) || password == "" || strings.ContainsAny(password, "\r\n\x00") {
		return errBadCredentials
	}
	allowed, err := userAllowed(user)
	if err != nil {
		log.Printf("reading users file: %v", err)
		return errors.New("internal error")
	}
	if !allowed {
		return errNotAllowed
	}

	// Kanidm softlocks the account itself; this just keeps us from being
	// the thing that trips it for everyone.
	keys := []string{"user:" + user, "ip:" + ip}
	if s.limited(keys) {
		return errRateLimited
	}

	ok, err := s.verifyKanidm(ctx, user, password)
	if err != nil {
		log.Printf("kanidm verify for %s: %v", user, err)
		return errors.New("could not reach kanidm")
	}
	if !ok {
		s.recordFailure(keys)
		log.Printf("bad unix password for %s from %s", user, ip)
		return errBadCredentials
	}

	if err := setKerberosPassword(ctx, user, password); err != nil {
		log.Printf("kadmin cpw %s: %v", user, err)
		return errors.New("could not update the Kerberos key")
	}
	log.Printf("synced Kerberos key for %s from %s", user, ip)
	return nil
}

func userAllowed(user string) (bool, error) {
	data, err := os.ReadFile(*usersFile)
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == user {
			return true, nil
		}
	}
	return false, nil
}

func (s *server) prune(key string, now time.Time) []time.Time {
	kept := s.failures[key][:0]
	for _, t := range s.failures[key] {
		if now.Sub(t) < failWindow {
			kept = append(kept, t)
		}
	}
	if len(kept) == 0 {
		delete(s.failures, key)
		return nil
	}
	s.failures[key] = kept
	return kept
}

func (s *server) limited(keys []string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for _, k := range keys {
		if len(s.prune(k, now)) >= failThreshold {
			return true
		}
	}
	return false
}

func (s *server) recordFailure(keys []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for _, k := range keys {
		s.failures[k] = append(s.prune(k, now), now)
	}
}

// verifyKanidm checks a unix password the same way kanidm-unixd does:
// authenticate as anonymous, then POST to the account's _unix/_auth.
func (s *server) verifyKanidm(ctx context.Context, user, password string) (bool, error) {
	token, err := s.kanidmAnonymousToken(ctx)
	if err != nil {
		return false, fmt.Errorf("anonymous auth: %w", err)
	}

	body, _ := json.Marshal(map[string]string{"value": password})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, *kanidmURL+"/v1/account/"+user+"/_unix/_auth", bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := s.client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		// No such account (or no unix extension)
		return false, nil
	default:
		return false, fmt.Errorf("unix auth: HTTP %d", resp.StatusCode)
	}

	// null on a wrong password, a UnixUserToken otherwise
	var tok *struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tok); err != nil {
		return false, fmt.Errorf("decoding unix auth response: %w", err)
	}
	return tok != nil && tok.Name == user, nil
}

func (s *server) kanidmAnonymousToken(ctx context.Context) (string, error) {
	steps := []any{
		map[string]any{"init2": map[string]any{"username": "anonymous", "issue": "token", "privileged": false}},
		map[string]any{"begin": "anonymous"},
		map[string]any{"cred": "anonymous"},
	}
	sessionID := ""
	for _, step := range steps {
		body, _ := json.Marshal(map[string]any{"step": step})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, *kanidmURL+"/v1/auth", bytes.NewReader(body))
		if err != nil {
			return "", err
		}
		req.Header.Set("Content-Type", "application/json")
		if sessionID != "" {
			req.Header.Set("X-KANIDM-AUTH-SESSION-ID", sessionID)
		}
		resp, err := s.client.Do(req)
		if err != nil {
			return "", err
		}
		var out struct {
			State map[string]json.RawMessage `json:"state"`
		}
		err = json.NewDecoder(resp.Body).Decode(&out)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return "", fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		if err != nil {
			return "", err
		}
		if id := resp.Header.Get("X-KANIDM-AUTH-SESSION-ID"); id != "" {
			sessionID = id
		}
		if raw, ok := out.State["success"]; ok {
			var token string
			if err := json.Unmarshal(raw, &token); err != nil {
				return "", err
			}
			return token, nil
		}
	}
	return "", errors.New("anonymous auth did not succeed")
}

func setKerberosPassword(ctx context.Context, user, password string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, *kadminPath,
		"-r", *realm,
		"-p", *adminPrinc+"@"+*realm,
		"-k", "-t", *keytabPath,
		"-q", "cpw "+user,
	)
	// Password (and confirmation) on stdin, so it never shows up in argv
	cmd.Stdin = strings.NewReader(password + "\n" + password + "\n")
	out, err := cmd.CombinedOutput()
	// kadmin exits 0 even when the query fails
	want := fmt.Sprintf("Password for \"%s@%s\" changed.", user, *realm)
	if err != nil || !bytes.Contains(out, []byte(want)) {
		return fmt.Errorf("%v: %s", err, bytes.TrimSpace(out))
	}
	return nil
}

type pageData struct {
	User    string
	CSRF    string
	Error   string
	Success bool
}

func (s *server) render(w http.ResponseWriter, status int, data pageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := pageTmpl.Execute(w, struct {
		pageData
		Realm   string
		SMBHost string
	}{data, *realm, *nasHostname}); err != nil {
		log.Printf("rendering page: %v", err)
	}
}

var pageTmpl = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kerberos sync</title>
<style>
:root { color-scheme: light dark; --bg: #fafafa; --fg: #1a1a1a; --muted: #666; --card: #fff; --line: #ddd; --accent: #2563eb; --ok: #15803d; --err: #b91c1c; }
@media (prefers-color-scheme: dark) { :root { --bg: #111; --fg: #eee; --muted: #999; --card: #1b1b1b; --line: #333; --accent: #60a5fa; --ok: #4ade80; --err: #f87171; } }
body { background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, sans-serif; margin: 0; padding: 2rem 1rem; }
main { max-width: 36rem; margin: 0 auto; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 1.25rem; margin-bottom: 1.5rem; }
h1 { font-size: 1.4rem; margin: 0 0 1rem; }
h2 { font-size: 1.05rem; margin: 1.5rem 0 .5rem; }
p, li { color: var(--fg); }
.muted { color: var(--muted); }
label { display: block; font-weight: 600; margin-bottom: .35rem; }
input[type=password] { width: 100%; box-sizing: border-box; padding: .55rem .7rem; font: inherit; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); color: var(--fg); }
button { margin-top: .9rem; padding: .55rem 1.1rem; font: inherit; font-weight: 600; border: 0; border-radius: 6px; background: var(--accent); color: #fff; cursor: pointer; }
code, pre { font-family: ui-monospace, monospace; font-size: .9em; }
pre { background: var(--bg); border: 1px solid var(--line); border-radius: 6px; padding: .6rem .8rem; overflow-x: auto; }
.ok { color: var(--ok); font-weight: 600; }
.err { color: var(--err); font-weight: 600; }
</style>
</head>
<body>
<main>
<div class="card">
<h1>Kerberos sync</h1>
<p class="muted">Signed in as <strong>{{.User}}</strong>. Enter your kanidm unix password to set it as your Kerberos password for <code>{{.User}}@{{.Realm}}</code>. Do this again whenever you change your unix password.</p>
{{if .Success}}<p class="ok">Done. Your Kerberos password now matches your unix password.</p>{{end}}
{{if .Error}}<p class="err">{{.Error}}</p>{{end}}
<form method="post">
<input type="hidden" name="csrf" value="{{.CSRF}}">
<label for="password">Unix password</label>
<input type="password" id="password" name="password" autocomplete="current-password" required autofocus>
<button type="submit">Sync</button>
</form>
</div>

<div class="card">
<h2>macOS</h2>
<pre>kinit --keychain {{.User}}@{{.Realm}}</pre>
<p>Saves the password in the keychain so tickets renew on their own. Then connect in Finder to <code>smb://{{.SMBHost}}</code>. Always use the full name, not an IP or <code>.local</code>.</p>
<h2>Linux</h2>
<pre>kinit {{.User}}@{{.Realm}}</pre>
<p>Or set up <code>pam_krb5</code> to get a ticket at login. Then mount with <code>sec=krb5</code> or open <code>smb://{{.SMBHost}}</code> in your file manager.</p>
</div>
</main>
</body>
</html>
`))
