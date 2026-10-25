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
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

// The UniFi PDU's own SNMP agent has no outlet data, so this goes through the
// UniFi Network controller instead.
type unifiPDUOptions struct {
	// Controller is the UniFi OS console base URL, e.g. https://unifi.example.
	Controller string `json:"controller"`
	Site       string `json:"site"`
	// MAC of the PDU as the controller knows it.
	MAC string `json:"mac"`
	// APIKeyEnv names the environment variable holding a UniFi API key. Used
	// when set; otherwise the module logs in as a local user.
	APIKeyEnv string `json:"api_key_env"`
	// UsernameEnv/PasswordEnv name the environment variables holding a local
	// UniFi OS user (a local-only, view-only admin is enough).
	UsernameEnv string `json:"username_env"`
	PasswordEnv string `json:"password_env"`
	// Insecure skips TLS verification for consoles with self-signed certs.
	Insecure bool `json:"insecure"`
	Outlets  int  `json:"outlets"`
	Rows     int  `json:"rows"`
}

type unifiPDU struct {
	env    *Env
	dev    *config.Device
	opts   unifiPDUOptions
	client *http.Client

	loginMu  sync.Mutex
	loggedIn bool
}

func init() {
	register(Spec{
		Name:        "unifi-pdu-pro",
		Description: "UniFi USP-PDU-Pro, per-outlet power via the UniFi Network API. Options: controller, site, mac, api_key_env or username_env/password_env, insecure, outlets, rows.",
		Height:      2,
		New: newUnifiPDU(unifiPDUOptions{
			Site:        "default",
			APIKeyEnv:   "UNIFI_API_KEY",
			UsernameEnv: "UNIFI_USERNAME",
			PasswordEnv: "UNIFI_PASSWORD",
			Outlets:     20,
			Rows:        2,
		}),
	})
}

func newUnifiPDU(defaults unifiPDUOptions) func(*Env, *config.Device) (Driver, error) {
	return func(env *Env, dev *config.Device) (Driver, error) {
		opts, err := decodeOptions(dev, defaults)
		if err != nil {
			return nil, err
		}
		if opts.Controller == "" || opts.MAC == "" {
			return nil, fmt.Errorf("device %s: controller and mac are required", dev.ID)
		}
		opts.Controller = strings.TrimRight(opts.Controller, "/")
		opts.MAC = strings.ToLower(opts.MAC)
		// Own client: the session login keeps its cookie in the jar.
		jar, _ := cookiejar.New(nil)
		client := &http.Client{Timeout: env.HTTP.Timeout, Jar: jar}
		if opts.Insecure {
			client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
		}
		return &unifiPDU{env: env, dev: dev, opts: opts, client: client}, nil
	}
}

func (p *unifiPDU) skeletonOutlets(n int) rack.Group {
	g := rack.Group{ID: "outlets", Kind: rack.KindOutlet, Label: "Outlets", Rows: p.opts.Rows}
	for i := 1; i <= n; i++ {
		g.Slots = append(g.Slots, rack.Slot{ID: strconv.Itoa(i), Label: strconv.Itoa(i), Status: rack.StatusUnknown})
	}
	return g
}

func (p *unifiPDU) Skeleton() rack.State {
	return rack.State{Status: rack.StatusUnknown, Faceplate: []rack.Group{p.skeletonOutlets(p.opts.Outlets)}}
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

type unifiOutlet struct {
	Index       int       `json:"index"`
	Name        string    `json:"name"`
	RelayState  bool      `json:"relay_state"`
	HasMetering *bool     `json:"has_metering"`
	Power       flexFloat `json:"outlet_power"`
	Voltage     flexFloat `json:"outlet_voltage"`
	Current     flexFloat `json:"outlet_current"`
	PowerFactor flexFloat `json:"outlet_power_factor"`
}

type unifiDevice struct {
	Name        string        `json:"name"`
	Model       string        `json:"model"`
	Version     string        `json:"version"`
	State       int           `json:"state"`
	Uptime      flexFloat     `json:"uptime"`
	Outlets     []unifiOutlet `json:"outlet_table"`
	TotalPower  flexFloat     `json:"outlet_ac_power_consumption"`
	PowerBudget flexFloat     `json:"outlet_ac_power_budget"`
}

// login starts a UniFi OS session; the TOKEN cookie lands in the client's jar.
func (p *unifiPDU) login(ctx context.Context) error {
	user, pass := os.Getenv(p.opts.UsernameEnv), os.Getenv(p.opts.PasswordEnv)
	if user == "" || pass == "" {
		return fmt.Errorf("no credentials: set $%s, or $%s and $%s", p.opts.APIKeyEnv, p.opts.UsernameEnv, p.opts.PasswordEnv)
	}
	body, _ := json.Marshal(map[string]any{"username": user, "password": pass, "rememberMe": true})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.opts.Controller+"/api/auth/login", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("login: HTTP %d", resp.StatusCode)
	}
	return nil
}

func (p *unifiPDU) get(ctx context.Context, url string) (*http.Response, error) {
	key := os.Getenv(p.opts.APIKeyEnv)
	for attempt := 0; ; attempt++ {
		if key == "" {
			p.loginMu.Lock()
			if !p.loggedIn {
				if err := p.login(ctx); err != nil {
					p.loginMu.Unlock()
					return nil, err
				}
				p.loggedIn = true
			}
			p.loginMu.Unlock()
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		if key != "" {
			req.Header.Set("X-API-KEY", key)
		}
		req.Header.Set("Accept", "application/json")
		resp, err := p.client.Do(req)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode == http.StatusUnauthorized && key == "" && attempt == 0 {
			// Session expired: log in again once.
			_ = resp.Body.Close()
			p.loginMu.Lock()
			p.loggedIn = false
			p.loginMu.Unlock()
			continue
		}
		return resp, nil
	}
}

func (p *unifiPDU) Poll(ctx context.Context) (rack.State, error) {
	url := fmt.Sprintf("%s/proxy/network/api/s/%s/stat/device/%s", p.opts.Controller, p.opts.Site, p.opts.MAC)
	resp, err := p.get(ctx, url)
	if err != nil {
		return rack.State{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return rack.State{}, fmt.Errorf("controller: HTTP %d", resp.StatusCode)
	}
	var body struct {
		Data []unifiDevice `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return rack.State{}, fmt.Errorf("controller: %w", err)
	}
	if len(body.Data) == 0 {
		return rack.State{}, fmt.Errorf("controller does not know %s", p.opts.MAC)
	}
	d := body.Data[0]

	outlets := d.Outlets
	sort.Slice(outlets, func(i, j int) bool { return outlets[i].Index < outlets[j].Index })
	n := max(len(outlets), p.opts.Outlets)
	group := p.skeletonOutlets(n)
	byIndex := map[int]*rack.Slot{}
	for i := range group.Slots {
		byIndex[i+1] = &group.Slots[i]
	}

	st := rack.State{Status: rack.StatusOK}
	var sum float64
	table := rack.Section{Title: "Outlets"}
	for _, o := range outlets {
		slot := byIndex[o.Index]
		if slot == nil {
			continue
		}
		name := o.Name
		if name == "" {
			name = fmt.Sprintf("Outlet %d", o.Index)
		}
		metered := o.HasMetering == nil || *o.HasMetering
		sec := rack.Section{Title: name}
		sec.Add("Outlet", strconv.Itoa(o.Index))
		if o.RelayState {
			slot.Status = rack.StatusOK
			sec.AddStatus("Relay", "on", rack.StatusOK)
		} else {
			slot.Status = rack.StatusOff
			sec.AddStatus("Relay", "off", rack.StatusOff)
		}
		row := "off"
		if o.RelayState {
			row = "on"
		}
		if metered {
			w := float64(o.Power)
			sum += w
			slot.Value = formatFloat(w, "W")
			sec.Add("Power", fmt.Sprintf("%.1f W", w))
			sec.Add("Current", fmt.Sprintf("%.2f A", float64(o.Current)))
			sec.Add("Voltage", fmt.Sprintf("%.1f V", float64(o.Voltage)))
			if o.PowerFactor > 0 {
				sec.Add("Power factor", fmt.Sprintf("%.2f", float64(o.PowerFactor)))
			}
			row = fmt.Sprintf("%s · %.1f W", row, w)
		}
		slot.Label = strconv.Itoa(o.Index)
		slot.Sections = []rack.Section{sec}
		table.AddStatus(fmt.Sprintf("%d %s", o.Index, name), row, slot.Status)
	}

	total := float64(d.TotalPower)
	if total == 0 {
		total = sum
	}
	info := rack.Section{Title: "PDU"}
	val := fmt.Sprintf("%.0f W", total)
	if d.PowerBudget > 0 {
		val += fmt.Sprintf(" / %.0f W", float64(d.PowerBudget))
	}
	info.Add("Total power", val)
	info.Add("Model", d.Model)
	info.Add("Firmware", d.Version)
	if d.Uptime > 0 {
		info.Add("Uptime", formatDuration(time.Duration(d.Uptime)*time.Second))
	}
	if d.State != 1 {
		// 1 is "connected" in the controller's device state enum.
		info.AddStatus("Controller state", strconv.Itoa(d.State), rack.StatusWarn)
		st.Status = rack.StatusWarn
	}

	st.Faceplate = []rack.Group{group}
	st.Sections = []rack.Section{info, table}
	st.Summary = fmt.Sprintf("%.0f W", total)
	st.Rollup()
	return st, nil
}
