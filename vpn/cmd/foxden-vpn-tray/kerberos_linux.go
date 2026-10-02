package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/FoxDenHome/core/vpn/internal/pkinit"
)

// Kerberos keeps a ticket for the device owner in the desktop session's
// default credential cache, so SMB (Dolphin, gvfs, mount.cifs sec=krb5) works
// without a password. The certificate comes from the portal through the
// daemon, which proves the device; the PKINIT key stays in the session.

const (
	krbCheckInterval = 15 * time.Minute
	krbRenewAfter    = 18 * time.Hour // tickets last a day
)

type kerberos struct {
	t        *tray
	dir      string
	sysConf  string // the system krb5.conf layered under ours
	kinit    func(ctx context.Context, env []string, args ...string) error
	klistOK  func(ctx context.Context, env []string, principal string) bool
	mStatus  *systray.MenuItem
	mRenew   *systray.MenuItem
	kick     chan struct{}
	mu       sync.Mutex
	renewed  time.Time
	principl string
	err      string
}

func newKerberos(t *tray) *kerberos {
	dir := filepath.Join(os.Getenv("HOME"), ".local", "share", "foxden-vpn")
	if x := os.Getenv("XDG_DATA_HOME"); x != "" {
		dir = filepath.Join(x, "foxden-vpn")
	}
	return &kerberos{t: t, dir: dir, sysConf: "/etc/krb5.conf", kinit: runKinit, klistOK: klistHas, kick: make(chan struct{}, 1)}
}

// menu adds the ticket status and renewal to parent (the NAS Shares menu).
func (k *kerberos) menu(parent *systray.MenuItem) {
	k.mStatus = parent.AddSubMenuItem("Checking…", "Kerberos ticket for the NAS, from this device's registration")
	k.mStatus.Disable()
	k.mRenew = parent.AddSubMenuItem("Get New Kerberos Ticket", "")
	go func() {
		for range k.mRenew.ClickedCh {
			k.mu.Lock()
			k.renewed = time.Time{}
			k.mu.Unlock()
			k.poke()
		}
	}()
}

func (k *kerberos) poke() {
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *kerberos) run() {
	t := time.NewTicker(krbCheckInterval)
	defer t.Stop()
	for {
		k.ensure(context.Background())
		k.render()
		select {
		case <-t.C:
		case <-k.kick:
		}
	}
}

func (k *kerberos) render() {
	if k.mStatus == nil {
		return
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	switch {
	case k.err != "":
		k.t.ui.title(k.mStatus, "Not signed in: "+truncate(k.err, 70))
	case k.principl != "":
		k.t.ui.title(k.mStatus, "Signed in as "+k.principl+", renews at "+clock(k.renewed.Add(krbRenewAfter)))
	default:
		k.t.ui.title(k.mStatus, "Checking…")
	}
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n-1] + "…"
	}
	return s
}

func (k *kerberos) fail(err error) {
	k.mu.Lock()
	k.err, k.principl = err.Error(), ""
	k.mu.Unlock()
}

// ensure renews the ticket when it is old, missing, or for someone else.
func (k *kerberos) ensure(ctx context.Context) {
	st := k.t.status()
	if st == nil || !st.Provisioned {
		k.fail(errors.New("this device is not registered"))
		return
	}
	if _, err := exec.LookPath("kinit"); err != nil {
		k.fail(errors.New("kinit not found, install krb5"))
		return
	}
	env := k.env()
	k.mu.Lock()
	fresh := !k.renewed.IsZero() && time.Since(k.renewed) < krbRenewAfter
	principal := k.principl
	k.mu.Unlock()
	if fresh && principal != "" && k.klistOK(ctx, env, principal) {
		return
	}
	if err := k.renew(ctx, env); err != nil {
		k.fail(err)
	}
}

func (k *kerberos) env() []string {
	conf := filepath.Join(k.dir, "krb5.conf")
	if _, err := os.Stat(k.sysConf); err == nil {
		conf += ":" + k.sysConf // ours first; the system's default_ccache_name still applies
	}
	return append(os.Environ(), "KRB5_CONFIG="+conf)
}

func (k *kerberos) renew(ctx context.Context, env []string) error {
	if err := os.MkdirAll(k.dir, 0o700); err != nil {
		return err
	}
	key, err := k.sessionKey()
	if err != nil {
		return err
	}
	der, err := x509.MarshalPKIXPublicKey(key.Public())
	if err != nil {
		return err
	}
	cert, err := k.t.client.KerberosCert(base64.StdEncoding.EncodeToString(der))
	if err != nil {
		return err
	}
	certFile, caFile := filepath.Join(k.dir, "pkinit.pem"), filepath.Join(k.dir, "pkinit-ca.pem")
	realm := cert.Principal[strings.LastIndex(cert.Principal, "@")+1:]
	conf := fmt.Sprintf(`# Written by foxden-vpn-tray.
[libdefaults]
  dns_lookup_kdc = true

[realms]
  %[1]s = {
    pkinit_anchors = FILE:%[2]s
  }

[domain_realm]
  .%[3]s = %[1]s
  %[3]s = %[1]s
`, realm, caFile, strings.ToLower(realm))
	for name, data := range map[string]string{certFile: cert.Certificate, caFile: cert.CA, filepath.Join(k.dir, "krb5.conf"): conf} {
		if err := os.WriteFile(name, []byte(data), 0o600); err != nil {
			return err
		}
	}
	if err := k.kinit(ctx, env, "-X", "X509_user_identity=FILE:"+certFile+","+filepath.Join(k.dir, "pkinit.key"), cert.Principal); err != nil {
		return err
	}
	k.mu.Lock()
	k.renewed, k.principl, k.err = time.Now(), cert.Principal, ""
	k.mu.Unlock()
	if k.t.shares != nil {
		k.t.shares.poke() // mounts that waited for a ticket
	}
	return nil
}

// sessionKey loads or creates this session's PKINIT key.
func (k *kerberos) sessionKey() (*ecdsa.PrivateKey, error) {
	path := filepath.Join(k.dir, "pkinit.key")
	if b, err := os.ReadFile(path); err == nil {
		if s, err := pkinit.ParseKeyPEM(b); err == nil {
			if ec, ok := s.(*ecdsa.PrivateKey); ok {
				return ec, nil
			}
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	b, err := pkinit.KeyPEM(key)
	if err != nil {
		return nil, err
	}
	return key, os.WriteFile(path, b, 0o600)
}

func runKinit(ctx context.Context, env []string, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "kinit", args...)
	cmd.Env = env
	cmd.Stdin = nil // never fall back to a password prompt
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(out.String())
		msg = strings.TrimPrefix(msg, "kinit: ")
		if msg == "" {
			msg = err.Error()
		}
		return errors.New(msg)
	}
	return nil
}

// klistHas reports whether the default cache holds a valid ticket for principal.
func klistHas(ctx context.Context, env []string, principal string) bool {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "klist")
	cmd.Env = env
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	if !strings.Contains(string(out), "principal: "+principal) {
		return false
	}
	check := exec.CommandContext(ctx, "klist", "-s")
	check.Env = env
	return check.Run() == nil
}
