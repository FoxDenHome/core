package session

import (
	"encoding/json"
	"path/filepath"
	"sort"

	"github.com/FoxDenHome/core/packetfox/internal/journey"
	"github.com/FoxDenHome/core/packetfox/internal/sharkd"
)

// Row is one line of the packet list: Wireshark's columns plus where the
// packet was seen and how its journey ended.
type Row struct {
	Num     int            `json:"num"`
	Point   string         `json:"point"`
	TS      float64        `json:"ts"` // Unix seconds
	Src     string         `json:"src"`
	Dst     string         `json:"dst"`
	Proto   string         `json:"proto"`
	Length  string         `json:"len"`
	Info    string         `json:"info"`
	BG      string         `json:"bg,omitempty"`
	FG      string         `json:"fg,omitempty"`
	Journey int            `json:"journey,omitempty"`
	Hop     int            `json:"hop,omitempty"`
	Hops    int            `json:"hops,omitempty"`
	Status  journey.Status `json:"status,omitempty"`
}

func (s *Session) Frames(filter string, skip, limit int) ([]Row, error) {
	var rows []sharkd.FrameRow
	err := s.withShark(func(c *sharkd.Client) error {
		var err error
		rows, err = c.Frames(filter, skip, limit)
		return err
	})
	if err != nil {
		return nil, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	jc := s.journeyContext()
	verdicts := map[int]journey.Result{}
	out := make([]Row, 0, len(rows))
	for _, r := range rows {
		if r.Num < 1 || r.Num > len(s.tracker.Frames) || len(r.Columns) < 7 {
			continue
		}
		f := s.tracker.Frames[r.Num-1]
		row := Row{
			Num: r.Num, Point: f.Point, TS: float64(f.TS.UnixNano()) / 1e9,
			Src: r.Columns[2], Dst: r.Columns[3], Proto: r.Columns[4], Length: r.Columns[5], Info: r.Columns[6],
			BG: r.BG, FG: r.FG, Journey: f.Journey,
		}
		if f.Journey > 0 {
			res, ok := verdicts[f.Journey]
			if !ok {
				res = s.tracker.Analyze(f.Journey, jc)
				verdicts[f.Journey] = res
			}
			row.Hops = len(res.Hops)
			row.Status = res.Verdict.Status
			for i, h := range res.Hops {
				if h.Frame == r.Num {
					row.Hop = i + 1
				}
			}
		}
		out = append(out, row)
	}
	return out, nil
}

type FrameDetail struct {
	Num     int             `json:"num"`
	Point   string          `json:"point"`
	Detail  json.RawMessage `json:"detail"`
	Journey *journey.Result `json:"journey,omitempty"`
}

func (s *Session) Frame(num int) (*FrameDetail, error) {
	var raw json.RawMessage
	err := s.withShark(func(c *sharkd.Client) error {
		var err error
		raw, err = c.Frame(num)
		return err
	})
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	d := &FrameDetail{Num: num, Detail: raw}
	if num >= 1 && num <= len(s.tracker.Frames) {
		f := s.tracker.Frames[num-1]
		d.Point = f.Point
		if f.Journey > 0 {
			r := s.tracker.Analyze(f.Journey, s.journeyContext())
			d.Journey = &r
		}
	}
	return d, nil
}

func (s *Session) Check(filter string) error {
	return s.withShark(func(c *sharkd.Client) error { return c.Check(filter) })
}

func (s *Session) Follow(proto, filter string) (json.RawMessage, error) {
	var raw json.RawMessage
	err := s.withShark(func(c *sharkd.Client) error {
		var err error
		raw, err = c.Follow(proto, filter)
		return err
	})
	return raw, err
}

func (s *Session) Summary() journey.Summary {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tracker.Summarize(s.journeyContext())
}

// Journeys lists journeys, the ones with a given status only if set,
// newest first.
func (s *Session) Journeys(status journey.Status, at string, limit int) []journey.Result {
	s.mu.Lock()
	defer s.mu.Unlock()
	jc := s.journeyContext()
	var out []journey.Result
	for i := len(s.tracker.Journeys) - 1; i >= 0 && len(out) < limit; i-- {
		r := s.tracker.Analyze(s.tracker.Journeys[i].ID, jc)
		if status != "" && r.Verdict.Status != status {
			continue
		}
		if at != "" && r.Verdict.At != at {
			continue
		}
		out = append(out, r)
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].ID > out[b].ID })
	return out
}

func (s *Session) CaptureFile() string {
	return filepath.Join(s.dir, captureFile)
}

// Flushed is how many frames of the capture file are complete on disk.
func (s *Session) Flushed() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.flushed
}
