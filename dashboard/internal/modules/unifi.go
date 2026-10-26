package modules

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"os"
	"strconv"
	"strings"
	"sync"
)

// unifiOptions reach one device through the local UniFi Network controller.
// Modules embed it in their own options, so its fields sit at the top level.
type unifiOptions struct {
	// Controller is the UniFi OS console base URL, e.g. https://unifi.example.
	Controller string `json:"controller"`
	Site       string `json:"site"`
	// MAC of the device as the controller knows it.
	MAC string `json:"mac"`
	// APIKeyEnv names the environment variable holding a UniFi API key. Used
	// when set; otherwise the client logs in as a local user.
	APIKeyEnv string `json:"api_key_env"`
	// UsernameEnv/PasswordEnv name the environment variables holding a local
	// UniFi OS user (a local-only, view-only admin is enough).
	UsernameEnv string `json:"username_env"`
	PasswordEnv string `json:"password_env"`
	// Insecure skips TLS verification for consoles with self-signed certs.
	Insecure bool `json:"insecure"`
}

var unifiDefaults = unifiOptions{
	Site:        "default",
	APIKeyEnv:   "UNIFI_API_KEY",
	UsernameEnv: "UNIFI_USERNAME",
	PasswordEnv: "UNIFI_PASSWORD",
}

// withDefaults fills unset fields from unifiDefaults, for options that are
// decoded on their own rather than on top of a preset.
func (o unifiOptions) withDefaults() unifiOptions {
	if o.Site == "" {
		o.Site = unifiDefaults.Site
	}
	if o.APIKeyEnv == "" {
		o.APIKeyEnv = unifiDefaults.APIKeyEnv
	}
	if o.UsernameEnv == "" {
		o.UsernameEnv = unifiDefaults.UsernameEnv
	}
	if o.PasswordEnv == "" {
		o.PasswordEnv = unifiDefaults.PasswordEnv
	}
	return o
}

type unifiClient struct {
	opts   unifiOptions
	client *http.Client

	loginMu  sync.Mutex
	loggedIn bool
}

func newUnifiClient(env *Env, opts unifiOptions) (*unifiClient, error) {
	if opts.Controller == "" || opts.MAC == "" {
		return nil, fmt.Errorf("controller and mac are required")
	}
	opts.Controller = strings.TrimRight(opts.Controller, "/")
	opts.MAC = strings.ToLower(opts.MAC)
	// Own client: the session login keeps its cookie in the jar.
	jar, _ := cookiejar.New(nil)
	client := &http.Client{Timeout: env.HTTP.Timeout, Jar: jar}
	if opts.Insecure {
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	}
	return &unifiClient{opts: opts, client: client}, nil
}

// flexFloat accepts numbers and numeric strings; the controller sends both.
type flexFloat float64

func (f *flexFloat) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	if s == "" || s == "null" {
		return nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return nil
	}
	*f = flexFloat(v)
	return nil
}

// login starts a UniFi OS session; the TOKEN cookie lands in the client's jar.
func (u *unifiClient) login(ctx context.Context) error {
	user, pass := os.Getenv(u.opts.UsernameEnv), os.Getenv(u.opts.PasswordEnv)
	if user == "" || pass == "" {
		return fmt.Errorf("no credentials: set $%s, or $%s and $%s", u.opts.APIKeyEnv, u.opts.UsernameEnv, u.opts.PasswordEnv)
	}
	body, _ := json.Marshal(map[string]any{"username": user, "password": pass, "rememberMe": true})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.opts.Controller+"/api/auth/login", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := u.client.Do(req)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("login: HTTP %d", resp.StatusCode)
	}
	return nil
}

func (u *unifiClient) get(ctx context.Context, url string) (*http.Response, error) {
	key := os.Getenv(u.opts.APIKeyEnv)
	for attempt := 0; ; attempt++ {
		if key == "" {
			u.loginMu.Lock()
			if !u.loggedIn {
				if err := u.login(ctx); err != nil {
					u.loginMu.Unlock()
					return nil, err
				}
				u.loggedIn = true
			}
			u.loginMu.Unlock()
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		if key != "" {
			req.Header.Set("X-API-KEY", key)
		}
		req.Header.Set("Accept", "application/json")
		resp, err := u.client.Do(req)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode == http.StatusUnauthorized && key == "" && attempt == 0 {
			// Session expired: log in again once.
			_ = resp.Body.Close()
			u.loginMu.Lock()
			u.loggedIn = false
			u.loginMu.Unlock()
			continue
		}
		return resp, nil
	}
}

// device decodes the controller's stat/device entry for the configured MAC into out.
func (u *unifiClient) device(ctx context.Context, out any) error {
	url := fmt.Sprintf("%s/proxy/network/api/s/%s/stat/device/%s", u.opts.Controller, u.opts.Site, u.opts.MAC)
	resp, err := u.get(ctx, url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("controller: HTTP %d", resp.StatusCode)
	}
	var body struct {
		Data []json.RawMessage `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return fmt.Errorf("controller: %w", err)
	}
	if len(body.Data) == 0 {
		return fmt.Errorf("controller does not know %s", u.opts.MAC)
	}
	if err := json.Unmarshal(body.Data[0], out); err != nil {
		return fmt.Errorf("controller: %w", err)
	}
	return nil
}
