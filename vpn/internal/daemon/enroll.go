package daemon

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

const pendingKeyFile = "pending.key"

// EnrollStart returns the key the tray should enroll. With regenerate, a new
// key is made (or the pending one reused) and stays inactive until the
// portal accepts it, so cancelling keeps the device working.
func (d *Daemon) EnrollStart(regenerate bool) (api.EnrollStart, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !regenerate {
		return api.EnrollStart{PublicKey: d.key.PublicKey().String()}, nil
	}
	if d.pendingKey == nil {
		k, err := wgtypes.GeneratePrivateKey()
		if err != nil {
			return api.EnrollStart{}, err
		}
		if err := writeFileAtomic(filepath.Join(d.opts.StateDir, pendingKeyFile), []byte(k.String()+"\n"), 0o600); err != nil {
			return api.EnrollStart{}, err
		}
		d.pendingKey = &k
		log.Printf("generated pending key %s", k.PublicKey())
	}
	st := api.EnrollStart{PublicKey: d.pendingKey.PublicKey().String()}
	if d.prov != nil {
		st.Replace = d.prov.Name
	}
	return st, nil
}

func loadPendingKey(dir string) *wgtypes.Key {
	b, err := os.ReadFile(filepath.Join(dir, pendingKeyFile))
	if err != nil {
		return nil
	}
	k, err := wgtypes.ParseKey(strings.TrimSpace(string(b)))
	if err != nil {
		return nil
	}
	return &k
}

type portalCompleteResponse struct {
	Device string `json:"device"`
	Config string `json:"config"`
	Error  string `json:"error"`
}

// EnrollComplete finishes an enrollment the portal redirected to the tray:
// it answers the challenge with whichever of our keys it was sealed to,
// lets the portal register that key, and installs the configuration the
// portal returns (verified like any provisioning blob).
func (d *Daemon) EnrollComplete(ctx context.Context, token, challenge string) error {
	if d.opts.PortalURL == "" {
		return errors.New("no portal configured")
	}
	sealed, err := base64.RawURLEncoding.DecodeString(challenge)
	if err != nil {
		return errors.New("malformed challenge")
	}

	d.mu.Lock()
	candidates := []wgtypes.Key{d.key}
	if d.pendingKey != nil {
		candidates = append([]wgtypes.Key{*d.pendingKey}, candidates...)
	}
	d.mu.Unlock()
	var key wgtypes.Key
	var answer []byte
	for _, k := range candidates {
		if a, err := provision.AnswerChallenge(sealed, k, d.opts.ServerKey); err == nil {
			key, answer = k, a
			break
		}
	}
	if answer == nil {
		return errors.New("this enrollment is not for this device's key")
	}

	resp, err := d.callPortal(ctx, token, answer)
	if err != nil {
		return err
	}
	blob, err := base64.StdEncoding.DecodeString(resp.Config)
	if err != nil {
		return errors.New("portal returned a malformed configuration")
	}
	cfg, err := provision.Open(blob, key, d.opts.ServerKey)
	if err != nil {
		return fmt.Errorf("portal returned an unusable configuration: %w", err)
	}

	d.mu.Lock()
	if d.pendingKey != nil && *d.pendingKey == key {
		if err := writeFileAtomic(filepath.Join(d.opts.StateDir, "private.key"), []byte(key.String()+"\n"), 0o600); err != nil {
			d.mu.Unlock()
			return fmt.Errorf("saving the new key: %w", err)
		}
		if err := os.Remove(filepath.Join(d.opts.StateDir, pendingKeyFile)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			log.Printf("removing pending key: %v", err)
		}
		d.key, d.pendingKey = key, nil
		log.Printf("switched to the new key %s", key.PublicKey())
	}
	d.prov, d.provErr = cfg, nil
	d.provGen++
	d.enrolledAt = time.Now()
	d.nextFetch = time.Now().Add(unprovisionedRetry)
	d.nextLocation = time.Time{}
	d.mu.Unlock()
	if err := saveProvision(d.opts.StateDir, cfg); err != nil {
		log.Print(err)
	}
	log.Printf("enrolled as %q with %v", cfg.Name, cfg.Addresses)
	d.poke()
	return nil
}

func (d *Daemon) callPortal(ctx context.Context, token string, answer []byte) (*portalCompleteResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	body, _ := json.Marshal(map[string]string{"token": token, "answer": base64.StdEncoding.EncodeToString(answer)})
	url := strings.TrimSuffix(d.opts.PortalURL, "/") + "/api/enroll/complete"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	r, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("contacting the portal: %w", err)
	}
	defer r.Body.Close()
	var out portalCompleteResponse
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&out); err != nil {
		return nil, fmt.Errorf("portal: %s", r.Status)
	}
	if r.StatusCode != http.StatusOK {
		if out.Error == "" {
			out.Error = r.Status
		}
		return nil, fmt.Errorf("portal: %s", out.Error)
	}
	return &out, nil
}
