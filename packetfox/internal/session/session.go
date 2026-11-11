// Package session runs captures: it starts the sources, merges their
// packets into one pcapng file (one interface per capture point), tracks
// journeys, and serves the result through sharkd.
package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/gopacket/gopacket"
	"github.com/gopacket/gopacket/layers"
	"github.com/gopacket/gopacket/pcapgo"

	"github.com/FoxDenHome/core/packetfox/internal/filter"
	"github.com/FoxDenHome/core/packetfox/internal/journey"
	"github.com/FoxDenHome/core/packetfox/internal/model"
	"github.com/FoxDenHome/core/packetfox/internal/sharkd"
)

const captureFile = "capture.pcapng"

type SourceStatus struct {
	Device  string `json:"device"`
	State   string `json:"state"` // starting, running, stopped, error
	Message string `json:"message"`
	Packets int    `json:"packets"`
}

// Meta is what is kept about a session besides its packets.
type Meta struct {
	ID          string          `json:"id"`
	User        string          `json:"user"`
	Name        string          `json:"name"`
	Started     time.Time       `json:"started"`
	Ended       time.Time       `json:"ended,omitzero"`
	Filter      filter.Filter   `json:"filter"`
	Points      []model.Point   `json:"points"`
	Snaplen     int             `json:"snaplen"`
	MaxPackets  int             `json:"max_packets"`
	MaxDuration time.Duration   `json:"max_duration"`
	StopReason  string          `json:"stop_reason,omitempty"`
	Sources     []*SourceStatus `json:"sources"`
	Frames      int             `json:"frames"`
}

type Session struct {
	dir    string
	sharkd string

	mu      sync.Mutex
	meta    Meta
	running bool
	file    *os.File
	writer  *pcapgo.NgWriter
	ifaces  map[ifaceKey]int
	tracker *journey.Tracker
	flushed int
	cancel  context.CancelFunc
	done    chan struct{}

	sharkMu     sync.Mutex
	shark       *sharkd.Client
	sharkFrames int
	sharkLoaded time.Time
	lastUsed    time.Time
}

type ifaceKey struct {
	point string
	lt    layers.LinkType
}

func (s *Session) Meta() Meta {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.meta
	m.Frames = len(s.tracker.Frames)
	var srcs []*SourceStatus
	for _, st := range m.Sources {
		c := *st
		srcs = append(srcs, &c)
	}
	m.Sources = srcs
	return m
}

func (s *Session) Running() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.running
}

func (s *Session) saveMeta() error {
	m := s.meta
	m.Frames = len(s.tracker.Frames)
	raw, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(s.dir, "meta.json.tmp")
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(s.dir, "meta.json"))
}

// add writes one packet. Called by all sources at once.
func (s *Session) add(p model.Packet) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.running {
		return
	}
	if len(s.tracker.Frames) >= s.meta.MaxPackets {
		return
	}
	key := ifaceKey{p.Point, p.LinkType}
	id, ok := s.ifaces[key]
	if !ok {
		intf := pcapgo.NgInterface{
			Name: p.Point, LinkType: p.LinkType, SnapLength: uint32(s.meta.Snaplen),
			TimestampResolution: 9, Filter: s.meta.Filter.BPFExpr(),
		}
		for _, pt := range s.meta.Points {
			if pt.ID == p.Point {
				intf.Description = pt.Label
			}
		}
		var err error
		if s.writer == nil {
			s.writer, err = pcapgo.NewNgWriterInterface(s.file, intf, pcapgo.NgWriterOptions{
				SectionInfo: pcapgo.NgSectionInfo{Application: "PacketFox", Comment: "PacketFox session " + s.meta.ID},
			})
			id = 0
		} else {
			id, err = s.writer.AddInterface(intf)
		}
		if err != nil {
			log.Printf("session %s: %v", s.meta.ID, err)
			return
		}
		s.ifaces[key] = id
	}
	if p.Length < len(p.Data) {
		p.Length = len(p.Data)
	}
	ci := gopacket.CaptureInfo{Timestamp: p.TS, CaptureLength: len(p.Data), Length: p.Length, InterfaceIndex: id}
	if err := s.writer.WritePacket(ci, p.Data); err != nil {
		log.Printf("session %s: %v", s.meta.ID, err)
		return
	}
	s.tracker.Add(p.Point, p.TS, journey.Parse(p.LinkType, p.Data))
	for _, st := range s.meta.Sources {
		if st.Device == model.PointDevice(p.Point) {
			st.Packets++
		}
	}
}

func (s *Session) flush() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.writer == nil {
		return
	}
	if err := s.writer.Flush(); err != nil {
		log.Printf("session %s: %v", s.meta.ID, err)
		return
	}
	s.flushed = len(s.tracker.Frames)
}

func (s *Session) run(ctx context.Context, srcs []model.Source) {
	var wg sync.WaitGroup
	for i, src := range srcs {
		st := s.meta.Sources[i]
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := src.Run(ctx, s.add, func(state, msg string) {
				s.mu.Lock()
				st.State, st.Message = state, msg
				s.mu.Unlock()
			})
			s.mu.Lock()
			if err != nil && ctx.Err() == nil {
				st.State, st.Message = "error", err.Error()
			} else if st.State != "error" {
				st.State = "stopped"
			}
			s.mu.Unlock()
		}()
	}

	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(s.meta.MaxDuration)
	defer deadline.Stop()
	finished := make(chan struct{})
	go func() { wg.Wait(); close(finished) }()

	reason := ""
loop:
	for {
		select {
		case <-ctx.Done():
			reason = "stopped"
			break loop
		case <-deadline.C:
			reason = "time limit reached"
			break loop
		case <-finished:
			reason = "all sources ended"
			break loop
		case <-ticker.C:
			s.flush()
			s.mu.Lock()
			full := len(s.tracker.Frames) >= s.meta.MaxPackets
			s.mu.Unlock()
			if full {
				reason = "packet limit reached"
				break loop
			}
		}
	}
	s.cancel()
	// Sources clean up the routers before returning
	<-finished

	s.mu.Lock()
	s.running = false
	if s.writer != nil {
		_ = s.writer.Flush()
	}
	s.flushed = len(s.tracker.Frames)
	_ = s.file.Close()
	s.meta.Ended = time.Now()
	s.meta.StopReason = reason
	if err := s.saveMeta(); err != nil {
		log.Printf("session %s: %v", s.meta.ID, err)
	}
	s.mu.Unlock()
	close(s.done)
}

// Stop ends the capture and waits until the routers are cleaned up.
func (s *Session) Stop() {
	s.cancel()
	<-s.done
}

// open loads a finished session from disk, rebuilding its journeys.
func open(dir, sharkdBin string) (*Session, error) {
	raw, err := os.ReadFile(filepath.Join(dir, "meta.json"))
	if err != nil {
		return nil, err
	}
	s := &Session{dir: dir, sharkd: sharkdBin, tracker: journey.NewTracker(), done: make(chan struct{})}
	close(s.done)
	s.cancel = func() {}
	if err := json.Unmarshal(raw, &s.meta); err != nil {
		return nil, err
	}
	if s.meta.Ended.IsZero() {
		// pfox died during the capture
		s.meta.Ended = s.meta.Started
		s.meta.StopReason = "interrupted"
	}
	f, err := os.Open(filepath.Join(dir, captureFile))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return s, nil
		}
		return nil, err
	}
	defer f.Close()
	// Capture points differ in link type (Ethernet, raw IP, SLL)
	r, err := pcapgo.NewNgReader(f, pcapgo.NgReaderOptions{WantMixedLinkType: true})
	if err != nil {
		if errors.Is(err, io.EOF) {
			return s, nil
		}
		return nil, err
	}
	for {
		data, ci, err := r.ReadPacketData()
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
				log.Printf("session %s: reading capture: %v", s.meta.ID, err)
			}
			break
		}
		intf, err := r.Interface(ci.InterfaceIndex)
		if err != nil {
			break
		}
		s.tracker.Add(intf.Name, ci.Timestamp, journey.Parse(intf.LinkType, data))
	}
	s.flushed = len(s.tracker.Frames)
	return s, nil
}

func (s *Session) points() map[string]model.Point {
	out := map[string]model.Point{}
	for _, p := range s.meta.Points {
		out[p.ID] = p
	}
	return out
}

func (s *Session) journeyContext() journey.Context {
	active := map[string]bool{}
	for _, p := range s.meta.Points {
		active[p.ID] = true
	}
	return journey.Context{Points: s.points(), Active: active, Now: time.Now(), Running: s.running}
}

// withShark runs f against a sharkd that has every flushed frame loaded.
// While capturing, it reloads at most once a second.
func (s *Session) withShark(f func(*sharkd.Client) error) error {
	s.sharkMu.Lock()
	defer s.sharkMu.Unlock()
	s.mu.Lock()
	flushed, running := s.flushed, s.running
	s.mu.Unlock()
	s.lastUsed = time.Now()

	stale := s.shark == nil || s.sharkFrames != flushed
	if stale && running && s.shark != nil && time.Since(s.sharkLoaded) < time.Second {
		stale = false
	}
	if stale {
		if flushed == 0 {
			return &sharkd.Error{Message: "no packets captured yet"}
		}
		if s.shark != nil {
			s.shark.Close()
			s.shark = nil
		}
		c, err := sharkd.Start(s.sharkd, filepath.Join(filepath.Dir(s.dir), ".sharkd-home"))
		if err != nil {
			return err
		}
		max := flushed
		if !running {
			max = 0
		}
		if err := c.Load(filepath.Join(s.dir, captureFile), max); err != nil {
			c.Close()
			return fmt.Errorf("loading capture: %w", err)
		}
		s.shark, s.sharkFrames, s.sharkLoaded = c, flushed, time.Now()
	}
	err := f(s.shark)
	var se *sharkd.Error
	if err != nil && !errors.As(err, &se) {
		s.shark.Close()
		s.shark = nil
	}
	return err
}

// closeIdle stops sharkd if nobody looked at the session for a while.
func (s *Session) closeIdle(after time.Duration) {
	s.sharkMu.Lock()
	defer s.sharkMu.Unlock()
	if s.shark != nil && time.Since(s.lastUsed) > after {
		s.shark.Close()
		s.shark = nil
	}
}
