// Package services installs and keeps up to date auxiliary services the user
// opted into on this device, such as shutdownd.
//
// Which services are wanted is device state (the daemon's settings): a
// service is unmanaged until the user enables or disables it, so turning this
// on never touches services that were installed by hand. Every artifact is
// pinned by sha256; nothing unpinned is ever installed.
package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"sync"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
)

// Artifact is a pinned download.
type Artifact struct {
	URL    string
	SHA256 string
}

// Service describes one installable service.
type Service struct {
	Name        string
	Description string
	// Version is shown to the user, e.g. the commit the artifacts were built from.
	Version string
	// Artifacts by GOOS/GOARCH.
	Artifacts map[string]Artifact
	// installer is the per-OS install logic; nil when the OS is unsupported.
	installer installer
}

// installer applies a service to the system. Implementations must be
// idempotent: Install is called on every reconcile.
type installer interface {
	// Detect reports whether the service is present at all, managed or not.
	Detect(sys *System) (installed bool, detail string)
	Install(ctx context.Context, sys *System, binary string) (detail string, err error)
	Remove(ctx context.Context, sys *System) error
}

func (s *Service) artifact() (Artifact, bool) {
	a, ok := s.Artifacts[runtime.GOOS+"/"+runtime.GOARCH]
	return a, ok
}

// Catalog lists the services this build knows about.
var Catalog = []*Service{shutdownd}

func lookup(name string) *Service {
	for _, s := range Catalog {
		if s.Name == name {
			return s
		}
	}
	return nil
}

// Known reports whether name is a service in the catalog.
func Known(name string) bool { return lookup(name) != nil }

// Manager reconciles the services against the wanted state.
type Manager struct {
	catalog  []*Service
	sys      *System
	cacheDir string
	http     *http.Client
	wake     chan struct{}

	mu     sync.Mutex
	wanted map[string]bool // absent: unmanaged
	status map[string]api.Service
}

const reconcileInterval = 10 * time.Minute

func NewManager(stateDir string) *Manager {
	return &Manager{
		catalog:  Catalog,
		sys:      DefaultSystem(),
		cacheDir: filepath.Join(stateDir, "services"),
		http:     &http.Client{Timeout: 5 * time.Minute},
		wake:     make(chan struct{}, 1),
		wanted:   map[string]bool{},
		status:   map[string]api.Service{},
	}
}

// SetWanted updates which services are wanted and triggers a reconcile.
func (m *Manager) SetWanted(wanted map[string]bool) {
	m.mu.Lock()
	m.wanted = map[string]bool{}
	for k, v := range wanted {
		m.wanted[k] = v
	}
	m.mu.Unlock()
	select {
	case m.wake <- struct{}{}:
	default:
	}
}

func (m *Manager) Run(ctx context.Context) {
	t := time.NewTicker(reconcileInterval)
	defer t.Stop()
	for {
		m.reconcile(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-m.wake:
		}
	}
}

// Status lists every catalog service with its current state.
func (m *Manager) Status() []api.Service {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]api.Service, 0, len(m.catalog))
	for _, s := range m.catalog {
		st, ok := m.status[s.Name]
		if !ok {
			st = api.Service{Name: s.Name, Description: s.Description, State: api.ServicePending}
		}
		if w, ok := m.wanted[s.Name]; ok {
			st.Wanted = &w
		}
		out = append(out, st)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (m *Manager) setStatus(s *Service, state, detail string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	prev := m.status[s.Name]
	if prev.State != state || prev.Detail != detail {
		log.Printf("service %s: %s %s", s.Name, state, detail)
	}
	m.status[s.Name] = api.Service{Name: s.Name, Description: s.Description, Version: s.Version, State: state, Detail: detail}
}

func (m *Manager) reconcile(ctx context.Context) {
	m.mu.Lock()
	wanted := m.wanted
	m.mu.Unlock()

	for _, s := range m.catalog {
		want, managed := wanted[s.Name]
		if s.installer == nil {
			m.setStatus(s, api.ServiceUnsupported, "not available on "+runtime.GOOS+" yet")
			continue
		}
		art, ok := s.artifact()
		if !ok {
			m.setStatus(s, api.ServiceUnsupported, "no build for "+runtime.GOOS+"/"+runtime.GOARCH)
			continue
		}
		switch {
		case !managed:
			if installed, detail := s.installer.Detect(m.sys); installed {
				m.setStatus(s, api.ServiceUnmanaged, detail)
			} else {
				m.setStatus(s, api.ServiceNotInstalled, "")
			}
		case want:
			bin, err := m.fetch(ctx, s, art)
			if err != nil {
				m.setStatus(s, api.ServiceError, err.Error())
				continue
			}
			detail, err := s.installer.Install(ctx, m.sys, bin)
			if err != nil {
				m.setStatus(s, api.ServiceError, err.Error())
				continue
			}
			m.setStatus(s, api.ServiceRunning, detail)
		default:
			if err := s.installer.Remove(ctx, m.sys); err != nil {
				m.setStatus(s, api.ServiceError, err.Error())
				continue
			}
			m.setStatus(s, api.ServiceNotInstalled, "removed")
		}
	}
}

// fetch returns a local path to the verified artifact, downloading it into
// the cache if needed.
func (m *Manager) fetch(ctx context.Context, s *Service, a Artifact) (string, error) {
	if err := os.MkdirAll(m.cacheDir, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(m.cacheDir, s.Name+"-"+a.SHA256)
	if sum, err := fileSHA256(path); err == nil && sum == a.SHA256 {
		return path, nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.URL, nil)
	if err != nil {
		return "", err
	}
	resp, err := m.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("downloading %s: %w", s.Name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("downloading %s: %s", s.Name, resp.Status)
	}
	tmp, err := os.CreateTemp(m.cacheDir, s.Name+".download-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, h), io.LimitReader(resp.Body, 256<<20)); err != nil {
		tmp.Close()
		return "", fmt.Errorf("downloading %s: %w", s.Name, err)
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != a.SHA256 {
		return "", fmt.Errorf("downloaded %s does not match its pinned hash (got %s): the release changed, this build needs a new pin", s.Name, got[:16])
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return "", err
	}
	return path, nil
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
