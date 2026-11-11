package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"sync"
	"time"

	"github.com/FoxDenHome/core/packetfox/internal/config"
	"github.com/FoxDenHome/core/packetfox/internal/filter"
	"github.com/FoxDenHome/core/packetfox/internal/journey"
	"github.com/FoxDenHome/core/packetfox/internal/model"
	"github.com/FoxDenHome/core/packetfox/internal/sources"
)

type Manager struct {
	cfg *config.Config
	Inv *Inventory

	mu      sync.Mutex
	current *Session
	opened  map[string]*Session
}

func NewManager(cfg *config.Config, inv *Inventory) *Manager {
	m := &Manager{cfg: cfg, Inv: inv, opened: map[string]*Session{}}
	go m.janitor()
	return m
}

func (m *Manager) sessionsDir() string { return filepath.Join(m.cfg.DataDir, "sessions") }

// CleanupRouters removes rules a crashed pfox left behind.
func (m *Manager) CleanupRouters(ctx context.Context) {
	for _, r := range m.cfg.Routers {
		if err := sources.CleanupRouter(ctx, r, m.cfg.RouterOSPassword); err != nil {
			log.Printf("%s: cleanup: %v", r.Name, err)
		}
	}
}

type StartRequest struct {
	Name        string        `json:"name"`
	Filter      filter.Filter `json:"filter"`
	Points      []string      `json:"points"`
	Snaplen     int           `json:"snaplen"`
	MaxPackets  int           `json:"max_packets"`
	MaxDuration string        `json:"max_duration"`
}

func (m *Manager) Start(req StartRequest, user string) (*Session, error) {
	if err := req.Filter.Normalize(); err != nil {
		return nil, err
	}
	if len(req.Points) == 0 {
		return nil, errors.New("pick at least one capture point")
	}
	if req.Snaplen <= 0 || req.Snaplen > 262144 {
		req.Snaplen = 262144
	}
	if req.MaxPackets <= 0 || req.MaxPackets > m.cfg.Limits.MaxPackets {
		req.MaxPackets = m.cfg.Limits.MaxPackets
	}
	maxDur := m.cfg.Limits.MaxDuration.Duration
	if req.MaxDuration != "" {
		d, err := time.ParseDuration(req.MaxDuration)
		if err != nil {
			return nil, fmt.Errorf("max duration: %w", err)
		}
		if d > 0 && d < maxDur {
			maxDur = d
		}
	}

	var points []model.Point
	byDevice := map[string][]model.Point{}
	var order []string
	for _, id := range req.Points {
		p, err := m.Inv.ResolvePoint(id)
		if err != nil {
			return nil, err
		}
		points = append(points, p)
		if _, ok := byDevice[p.Device]; !ok {
			order = append(order, p.Device)
		}
		byDevice[p.Device] = append(byDevice[p.Device], p)
	}

	var srcs []model.Source
	for _, dev := range order {
		pts := byDevice[dev]
		switch pts[0].Kind {
		case model.KindRouter:
			idx := -1
			var router config.Router
			for i, r := range m.cfg.Routers {
				if r.Name == dev {
					idx, router = i, r
				}
			}
			var chains []string
			for _, p := range pts {
				chains = append(chains, p.Chain)
			}
			srcs = append(srcs, &sources.RouterSource{
				Router: router, Password: m.cfg.RouterOSPassword, Collector: m.cfg.Collector,
				Index: idx, LastPort: sources.RouterPort(m.cfg.Collector, len(m.cfg.Routers)-1, "postrouting"),
				Filter: req.Filter, Chains: chains,
			})
		default:
			sd, kind, auth, _ := m.Inv.sshDevice(dev)
			srcs = append(srcs, &sources.SSHSource{Kind: kind, Dev: sd, Auth: auth, Points: pts, Filter: req.Filter, Snaplen: req.Snaplen})
		}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.current != nil && m.current.Running() {
		m.mu.Unlock()
		m.current.Stop()
		m.mu.Lock()
	}

	id := time.Now().UTC().Format("20060102-150405")
	dir := filepath.Join(m.sessionsDir(), id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, captureFile), os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Session{
		dir: dir, sharkd: m.cfg.Sharkd, running: true, file: f,
		ifaces: map[ifaceKey]int{}, tracker: journey.NewTracker(), cancel: cancel, done: make(chan struct{}),
		meta: Meta{
			ID: id, User: user, Name: req.Name, Started: time.Now(), Filter: req.Filter, Points: points,
			Snaplen: req.Snaplen, MaxPackets: req.MaxPackets, MaxDuration: maxDur,
		},
	}
	for _, src := range srcs {
		s.meta.Sources = append(s.meta.Sources, &SourceStatus{Device: src.Device(), State: "starting"})
	}
	if err := s.saveMeta(); err != nil {
		cancel()
		f.Close()
		return nil, err
	}
	m.current = s
	m.opened[id] = s
	go s.run(ctx, srcs)
	m.prune()
	return s, nil
}

func (m *Manager) Current() *Session {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.current
}

func (m *Manager) Stop() {
	if s := m.Current(); s != nil {
		s.Stop()
	}
}

var idRe = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}$`)

func (m *Manager) Get(id string) (*Session, error) {
	if !idRe.MatchString(id) {
		return nil, os.ErrNotExist
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.opened[id]; ok {
		return s, nil
	}
	s, err := open(filepath.Join(m.sessionsDir(), id), m.cfg.Sharkd)
	if err != nil {
		return nil, err
	}
	m.opened[id] = s
	return s, nil
}

func (m *Manager) List() []Meta {
	entries, _ := os.ReadDir(m.sessionsDir())
	var out []Meta
	for _, e := range entries {
		if !idRe.MatchString(e.Name()) {
			continue
		}
		m.mu.Lock()
		s, ok := m.opened[e.Name()]
		m.mu.Unlock()
		if ok {
			out = append(out, s.Meta())
			continue
		}
		raw, err := os.ReadFile(filepath.Join(m.sessionsDir(), e.Name(), "meta.json"))
		if err != nil {
			continue
		}
		var meta Meta
		if json.Unmarshal(raw, &meta) == nil {
			out = append(out, meta)
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[a].ID > out[b].ID })
	return out
}

func (m *Manager) Delete(id string) error {
	s, err := m.Get(id)
	if err != nil {
		return err
	}
	if s.Running() {
		return errors.New("stop the capture first")
	}
	m.mu.Lock()
	delete(m.opened, id)
	m.mu.Unlock()
	s.closeIdle(0)
	return os.RemoveAll(s.dir)
}

// prune keeps the newest MaxSessions sessions. Called with m.mu held.
func (m *Manager) prune() {
	entries, _ := os.ReadDir(m.sessionsDir())
	var ids []string
	for _, e := range entries {
		if idRe.MatchString(e.Name()) {
			ids = append(ids, e.Name())
		}
	}
	sort.Strings(ids)
	for len(ids) > m.cfg.Limits.MaxSessions {
		id := ids[0]
		ids = ids[1:]
		if s, ok := m.opened[id]; ok {
			if s == m.current {
				continue
			}
			s.closeIdle(0)
			delete(m.opened, id)
		}
		_ = os.RemoveAll(filepath.Join(m.sessionsDir(), id))
	}
}

// janitor stops idle sharkd processes and forgets sessions nobody looks at.
func (m *Manager) janitor() {
	for range time.Tick(time.Minute) {
		m.mu.Lock()
		for id, s := range m.opened {
			s.closeIdle(10 * time.Minute)
			if s != m.current && !s.Running() && time.Since(s.lastUsedTime()) > 30*time.Minute {
				delete(m.opened, id)
			}
		}
		m.mu.Unlock()
	}
}

func (s *Session) lastUsedTime() time.Time {
	s.sharkMu.Lock()
	defer s.sharkMu.Unlock()
	return s.lastUsed
}
