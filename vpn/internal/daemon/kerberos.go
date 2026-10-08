package daemon

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"strings"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
)

// KerberosCert gets a PKINIT certificate for the device owner, for the
// public key of the tray's session. The daemon proves the device to the
// portal with its WireGuard key, which never leaves it.
func (d *Daemon) KerberosCert(ctx context.Context, sessionKey string) (api.KerberosCert, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	token, answer, err := d.proveDevice(ctx, "pkinit")
	if err != nil {
		return api.KerberosCert{}, err
	}
	var out api.KerberosCert
	err = d.portalJSON(ctx, "/api/kerberos/cert", map[string]string{
		"token": token, "answer": answer, "public_key": sessionKey,
	}, &out)
	return out, err
}

// proveDevice answers a portal challenge for purpose with the device key,
// returning the token and answer to hand back to the portal.
func (d *Daemon) proveDevice(ctx context.Context, purpose string) (token, answer string, err error) {
	if d.opts.PortalURL == "" {
		return "", "", errors.New("no portal configured")
	}
	d.mu.Lock()
	key, provisioned := d.key, d.prov != nil
	d.mu.Unlock()
	if !provisioned {
		return "", "", errors.New("this device is not registered")
	}
	var ch struct{ Token, Challenge string }
	if err := d.portalJSON(ctx, "/api/device/challenge", map[string]string{
		"public_key": key.PublicKey().String(), "purpose": purpose,
	}, &ch); err != nil {
		return "", "", err
	}
	sealed, err := base64.RawURLEncoding.DecodeString(ch.Challenge)
	if err != nil {
		return "", "", errors.New("portal sent a malformed challenge")
	}
	secret, err := provision.AnswerChallenge(sealed, key, d.opts.ServerKey)
	if err != nil {
		return "", "", fmt.Errorf("challenge: %w", err)
	}
	return ch.Token, base64.StdEncoding.EncodeToString(secret), nil
}

// ExposeTicket gets a ticket for opening tunnels on the expose edge. The
// edge is not reachable from the internet, so the tunnel has to be up.
func (d *Daemon) ExposeTicket(ctx context.Context) (api.ExposeTicket, error) {
	d.mu.Lock()
	prov, state := d.prov, d.state
	d.mu.Unlock()
	switch {
	case prov == nil:
		return api.ExposeTicket{}, errors.New("this device is not registered")
	case prov.Expose == nil || len(prov.Expose.Addresses) == 0:
		return api.ExposeTicket{}, errors.New("exposing ports is not offered to this device")
	case state == api.TunnelDown:
		return api.ExposeTicket{}, errors.New("the VPN tunnel is down; exposing ports works only through it")
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	token, answer, err := d.proveDevice(ctx, "expose")
	if err != nil {
		return api.ExposeTicket{}, err
	}
	var out api.ExposeTicket
	if err := d.portalJSON(ctx, "/api/expose/ticket", map[string]string{"token": token, "answer": answer}, &out); err != nil {
		return api.ExposeTicket{}, err
	}
	for _, a := range prov.Expose.Addresses {
		out.Edges = append(out.Edges, netip.AddrPortFrom(a, prov.Expose.Port).String())
	}
	out.ServerName = prov.Expose.ServerName
	return out, nil
}

func (d *Daemon) portalJSON(ctx context.Context, path string, body, out any) error {
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(d.opts.PortalURL, "/")+path, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("contacting the portal: %w", err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		var e struct{ Error string }
		if json.Unmarshal(data, &e) == nil && e.Error != "" {
			return fmt.Errorf("portal: %s", e.Error)
		}
		return fmt.Errorf("portal: %s", resp.Status)
	}
	return json.Unmarshal(data, out)
}
