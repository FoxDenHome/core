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
	"strings"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
)

// KerberosCert gets a PKINIT certificate for the device owner, for the
// public key of the tray's session. The daemon proves the device to the
// portal with its WireGuard key, which never leaves it.
func (d *Daemon) KerberosCert(ctx context.Context, sessionKey string) (api.KerberosCert, error) {
	if d.opts.PortalURL == "" {
		return api.KerberosCert{}, errors.New("no portal configured")
	}
	d.mu.Lock()
	key, provisioned := d.key, d.prov != nil
	d.mu.Unlock()
	if !provisioned {
		return api.KerberosCert{}, errors.New("this device is not registered")
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	var ch struct{ Token, Challenge string }
	if err := d.portalJSON(ctx, "/api/device/challenge", map[string]string{"public_key": key.PublicKey().String()}, &ch); err != nil {
		return api.KerberosCert{}, err
	}
	sealed, err := base64.RawURLEncoding.DecodeString(ch.Challenge)
	if err != nil {
		return api.KerberosCert{}, errors.New("portal sent a malformed challenge")
	}
	answer, err := provision.AnswerChallenge(sealed, key, d.opts.ServerKey)
	if err != nil {
		return api.KerberosCert{}, fmt.Errorf("challenge: %w", err)
	}
	var out api.KerberosCert
	err = d.portalJSON(ctx, "/api/kerberos/cert", map[string]string{
		"token": ch.Token, "answer": base64.StdEncoding.EncodeToString(answer), "public_key": sessionKey,
	}, &out)
	return out, err
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
