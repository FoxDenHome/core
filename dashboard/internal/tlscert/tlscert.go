// Package tlscert keeps a Let's Encrypt certificate for one domain. It is
// issued over DNS-01 through the dns.he.net dynamic TXT record at
// _acme-challenge.<domain>, so it works no matter which router the domain
// currently points at.
package tlscert

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	mrand "math/rand/v2"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/acme"
)

const (
	// renewBefore is how long before expiry a certificate is renewed.
	renewBefore = 30 * 24 * time.Hour
	// Let's Encrypt allows 5 failed validations per hostname and hour. Both
	// routers share the TXT record, so a clash is retried after a random wait.
	retryMin    = 15 * time.Minute
	retryJitter = 15 * time.Minute
)

var (
	heUpdateURL   = "https://dyn.dns.he.net/nic/update"
	heNameservers = []string{"ns1.he.net:53", "ns2.he.net:53", "ns3.he.net:53", "ns4.he.net:53", "ns5.he.net:53"}
	propagation   = 2 * time.Minute
	pollInterval  = 5 * time.Second
)

type Options struct {
	Domain string
	Email  string
	// Directory is the ACME directory URL. Defaults to Let's Encrypt.
	Directory string
	// CacheDir holds the account key and the issued certificate.
	CacheDir string
	// DNSKey is the dns.he.net DDNS key of _acme-challenge.<Domain>.
	DNSKey string
	HTTP   *http.Client
}

type Manager struct {
	opts Options
	cert atomic.Pointer[tls.Certificate]
}

// New loads a cached certificate if there is one.
func New(opts Options) (*Manager, error) {
	if opts.Domain == "" || opts.CacheDir == "" || opts.DNSKey == "" {
		return nil, errors.New("tls: domain, cache_dir and dns_key are required")
	}
	if opts.Directory == "" {
		opts.Directory = acme.LetsEncryptURL
	}
	if opts.HTTP == nil {
		opts.HTTP = http.DefaultClient
	}
	if err := os.MkdirAll(opts.CacheDir, 0o700); err != nil {
		return nil, err
	}
	m := &Manager{opts: opts}
	cert, err := tls.LoadX509KeyPair(m.path("cert.pem"), m.path("key.pem"))
	if err == nil {
		m.cert.Store(&cert)
	} else if !errors.Is(err, os.ErrNotExist) {
		log.Printf("tls: ignoring cached certificate: %v", err)
	}
	return m, nil
}

func (m *Manager) path(name string) string {
	return filepath.Join(m.opts.CacheDir, name)
}

func (m *Manager) GetCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	cert := m.cert.Load()
	if cert == nil {
		return nil, errors.New("tls: no certificate yet")
	}
	return cert, nil
}

// Run renews the certificate until ctx is done.
func (m *Manager) Run(ctx context.Context) {
	// Spread out the first attempt so both routers don't clash on the TXT
	// record right after a deploy.
	wait := time.Duration(mrand.Int64N(int64(2 * time.Minute)))
	for {
		if renewAt := renewalTime(m.cert.Load()); time.Until(renewAt) > wait {
			wait = time.Until(renewAt)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		if err := m.obtain(ctx); err != nil {
			wait = retryMin + time.Duration(mrand.Int64N(int64(retryJitter)))
			log.Printf("tls: obtaining certificate for %s: %v (retrying in %s)", m.opts.Domain, err, wait.Round(time.Second))
			continue
		}
		log.Printf("tls: got certificate for %s, valid until %s", m.opts.Domain, m.cert.Load().Leaf.NotAfter)
		wait = 0
	}
}

// renewalTime is when cert is due for renewal; the zero time if it's missing.
func renewalTime(cert *tls.Certificate) time.Time {
	if cert == nil || cert.Leaf == nil {
		return time.Time{}
	}
	return cert.Leaf.NotAfter.Add(-renewBefore)
}

func (m *Manager) obtain(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()

	key, err := m.accountKey()
	if err != nil {
		return err
	}
	client := &acme.Client{Key: key, DirectoryURL: m.opts.Directory, HTTPClient: m.opts.HTTP}
	account := &acme.Account{}
	if m.opts.Email != "" {
		account.Contact = []string{"mailto:" + m.opts.Email}
	}
	if _, err := client.Register(ctx, account, acme.AcceptTOS); err != nil && !errors.Is(err, acme.ErrAccountAlreadyExists) {
		return fmt.Errorf("registering account: %w", err)
	}

	order, err := client.AuthorizeOrder(ctx, acme.DomainIDs(m.opts.Domain))
	if err != nil {
		return fmt.Errorf("creating order: %w", err)
	}
	for _, authzURL := range order.AuthzURLs {
		if err := m.authorize(ctx, client, authzURL); err != nil {
			return err
		}
	}
	if order, err = client.WaitOrder(ctx, order.URI); err != nil {
		return fmt.Errorf("waiting for order: %w", err)
	}

	certKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	csr, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{DNSNames: []string{m.opts.Domain}}, certKey)
	if err != nil {
		return err
	}
	chain, _, err := client.CreateOrderCert(ctx, order.FinalizeURL, csr, true)
	if err != nil {
		return fmt.Errorf("finalizing order: %w", err)
	}
	return m.store(chain, certKey)
}

func (m *Manager) authorize(ctx context.Context, client *acme.Client, authzURL string) error {
	authz, err := client.GetAuthorization(ctx, authzURL)
	if err != nil {
		return fmt.Errorf("getting authorization: %w", err)
	}
	if authz.Status == acme.StatusValid {
		return nil
	}
	i := slices.IndexFunc(authz.Challenges, func(c *acme.Challenge) bool { return c.Type == "dns-01" })
	if i < 0 {
		return errors.New("no dns-01 challenge offered")
	}
	challenge := authz.Challenges[i]
	value, err := client.DNS01ChallengeRecord(challenge.Token)
	if err != nil {
		return err
	}
	if err := m.setTXT(ctx, value); err != nil {
		return fmt.Errorf("setting TXT record: %w", err)
	}
	if err := waitTXT(ctx, "_acme-challenge."+m.opts.Domain, value); err != nil {
		return err
	}
	if _, err := client.Accept(ctx, challenge); err != nil {
		return fmt.Errorf("accepting challenge: %w", err)
	}
	if _, err := client.WaitAuthorization(ctx, authz.URI); err != nil {
		return fmt.Errorf("waiting for authorization: %w", err)
	}
	return nil
}

// setTXT updates the dynamic TXT record through dns.he.net's DDNS API.
func (m *Manager) setTXT(ctx context.Context, value string) error {
	form := url.Values{
		"hostname": {"_acme-challenge." + m.opts.Domain},
		"password": {m.opts.DNSKey},
		"txt":      {value},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, heUpdateURL, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := m.opts.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
	reply := strings.TrimSpace(string(body))
	if resp.StatusCode != http.StatusOK || !(strings.HasPrefix(reply, "good") || strings.HasPrefix(reply, "nochg")) {
		return fmt.Errorf("HTTP %d: %q", resp.StatusCode, reply)
	}
	return nil
}

// waitTXT waits until every dns.he.net nameserver serves value for name.
func waitTXT(ctx context.Context, name, value string) error {
	deadline := time.Now().Add(propagation)
	pending := slices.Clone(heNameservers)
	for {
		pending = slices.DeleteFunc(pending, func(ns string) bool {
			records, err := resolverFor(ns).LookupTXT(ctx, name)
			return err == nil && slices.Contains(records, value)
		})
		if len(pending) == 0 {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("TXT record not visible on %s after %s", strings.Join(pending, ", "), propagation)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(pollInterval):
		}
	}
}

func resolverFor(nameserver string) *net.Resolver {
	return &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, network, nameserver)
		},
	}
}

func (m *Manager) accountKey() (crypto.Signer, error) {
	path := m.path("account.key")
	if raw, err := os.ReadFile(path); err == nil {
		block, _ := pem.Decode(raw)
		if block == nil {
			return nil, fmt.Errorf("%s: no PEM data", path)
		}
		return x509.ParseECPrivateKey(block.Bytes)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	if err := writeKey(path, key); err != nil {
		return nil, err
	}
	return key, nil
}

func (m *Manager) store(chain [][]byte, key *ecdsa.PrivateKey) error {
	var certPEM []byte
	for _, der := range chain {
		certPEM = append(certPEM, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})...)
	}
	keyPath := m.path("key.pem")
	if err := writeKey(keyPath, key); err != nil {
		return err
	}
	if err := writeFile(m.path("cert.pem"), certPEM); err != nil {
		return err
	}
	cert, err := tls.LoadX509KeyPair(m.path("cert.pem"), keyPath)
	if err != nil {
		return err
	}
	m.cert.Store(&cert)
	return nil
}

func writeKey(path string, key *ecdsa.PrivateKey) error {
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	return writeFile(path, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}))
}

// writeFile replaces path atomically, so a crash never leaves half a key.
func writeFile(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
