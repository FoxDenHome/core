package journey

import (
	"cmp"
	"fmt"
	"net/netip"
	"slices"
	"sort"
	"time"

	"github.com/FoxDenHome/core/packetfox/internal/model"
)

// Window is how far apart copies of one packet may be stamped. It covers
// transit time and the clock skew between devices.
const Window = 2 * time.Second

type Frame struct {
	Num     int
	Point   string
	TS      time.Time
	Info    Info
	Journey int
}

type Journey struct {
	ID     int
	Frames []int
	First  time.Time
	Last   time.Time
}

// Tracker groups frames into journeys as they arrive. It is not safe for
// concurrent use.
type Tracker struct {
	Frames   []Frame
	Journeys []*Journey
	open     map[uint64][]int
	newest   time.Time
	// TCP payload seen per capture point and flow, for recognizing
	// segments that a host's GRO merged (or TSO had not split yet)
	cover map[coverKey][]int
}

type coverKey struct {
	point            string
	src, dst         netip.Addr
	srcPort, dstPort uint16
}

func NewTracker() *Tracker {
	return &Tracker{open: map[uint64][]int{}, cover: map[coverKey][]int{}}
}

// Add records the next frame (numbered from 1) and returns its journey ID,
// or 0 for packets that aren't IP.
func (t *Tracker) Add(point string, ts time.Time, info Info) int {
	f := Frame{Num: len(t.Frames) + 1, Point: point, TS: ts, Info: info}
	if info.OK {
		f.Journey = t.join(f)
		if info.Proto == "TCP" && info.SeqLen > 0 {
			k := coverKey{point, info.Src, info.Dst, info.SrcPort, info.DstPort}
			t.cover[k] = append(t.cover[k], f.Num)
		}
	}
	t.Frames = append(t.Frames, f)
	if ts.After(t.newest) {
		t.newest = ts
	}
	if f.Num%4096 == 0 {
		t.sweep()
	}
	return f.Journey
}

func (t *Tracker) join(f Frame) int {
	ids := t.open[f.Info.Fingerprint]
	for i := len(ids) - 1; i >= 0; i-- {
		j := t.Journeys[ids[i]-1]
		if f.TS.Sub(j.First).Abs() > Window {
			continue
		}
		// The same point seeing the same packet at the same TTL is a
		// different packet (or a duplicate); seeing it again at a lower
		// TTL is a hairpin through the same router.
		dup := false
		for _, n := range j.Frames {
			o := t.Frames[n-1]
			if o.Point == f.Point && o.Info.TTL == f.Info.TTL {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		j.Frames = append(j.Frames, f.Num)
		if f.TS.After(j.Last) {
			j.Last = f.TS
		}
		if f.TS.Before(j.First) {
			j.First = f.TS
		}
		return j.ID
	}
	j := &Journey{ID: len(t.Journeys) + 1, Frames: []int{f.Num}, First: f.TS, Last: f.TS}
	t.Journeys = append(t.Journeys, j)
	t.open[f.Info.Fingerprint] = append(ids, j.ID)
	return j.ID
}

func (t *Tracker) sweep() {
	cutoff := t.newest.Add(-2 * Window)
	for fp, ids := range t.open {
		ids = slices.DeleteFunc(ids, func(id int) bool { return t.Journeys[id-1].Last.Before(cutoff) })
		if len(ids) == 0 {
			delete(t.open, fp)
		} else {
			t.open[fp] = ids
		}
	}
}

type Hop struct {
	Frame   int        `json:"frame"`
	Point   string     `json:"point"`
	TS      time.Time  `json:"-"`
	Unix    float64    `json:"ts"` // seconds
	TTL     uint8      `json:"ttl"`
	Src     netip.Addr `json:"src"`
	Dst     netip.Addr `json:"dst"`
	SrcPort uint16     `json:"sport,omitempty"`
	DstPort uint16     `json:"dport,omitempty"`
	// Milliseconds since the previous hop; only meaningful when SameClock.
	DeltaMS   *float64 `json:"delta_ms,omitempty"`
	SameClock bool     `json:"same_clock"`
	// The addresses or ports differ from the previous hop.
	NAT bool `json:"nat"`
}

type Status string

const (
	Delivered Status = "delivered"
	Consumed  Status = "consumed" // addressed to a router, which got it
	Dropped   Status = "dropped"  // a router saw it come in, but not go out
	Lost      Status = "lost"     // never reached the point its destination is behind
	InFlight  Status = "in-flight"
	Seen      Status = "seen" // no capture point to tell either way
)

type Verdict struct {
	Status Status `json:"status"`
	// Point the packet was last seen at, and the one it should have
	// reached next.
	At       string `json:"at,omitempty"`
	Expected string `json:"expected,omitempty"`
	Detail   string `json:"detail"`
}

type Result struct {
	ID      int     `json:"id"`
	Proto   string  `json:"proto"`
	Hops    []Hop   `json:"hops"`
	Verdict Verdict `json:"verdict"`
}

// Context is what Analyze needs to know about the capture.
type Context struct {
	Points  map[string]model.Point
	Active  map[string]bool
	Now     time.Time
	Running bool
}

func contains(addrs []netip.Addr, a netip.Addr) bool {
	return slices.Contains(addrs, a)
}

func (t *Tracker) Analyze(id int, c Context) Result {
	j := t.Journeys[id-1]
	r := Result{ID: id}
	for _, n := range j.Frames {
		f := t.Frames[n-1]
		r.Proto = f.Info.Proto
		r.Hops = append(r.Hops, Hop{
			Frame: f.Num, Point: f.Point, TS: f.TS, Unix: float64(f.TS.UnixNano()) / 1e9, TTL: f.Info.TTL,
			Src: f.Info.Src, Dst: f.Info.Dst, SrcPort: f.Info.SrcPort, DstPort: f.Info.DstPort,
		})
	}
	// The TTL orders hops across routers no matter how the clocks line up;
	// hops at the same TTL (bridges, netns, a router's own chains are
	// handled by TTL already) go by time.
	sort.SliceStable(r.Hops, func(a, b int) bool {
		ha, hb := r.Hops[a], r.Hops[b]
		if ha.TTL != hb.TTL {
			return ha.TTL > hb.TTL
		}
		pa, pb := c.Points[ha.Point], c.Points[hb.Point]
		// The sender's own capture point comes first, the receiver's last,
		// whatever their clocks say.
		if ra, rb := rank(pa, ha), rank(pb, hb); ra != rb {
			return ra < rb
		}
		if pa.Device == pb.Device && pa.Kind == model.KindRouter {
			// A router consuming or not decrementing (bridged): pre first
			return cmp.Compare(pa.Chain, pb.Chain) > 0
		}
		return ha.TS.Before(hb.TS)
	})
	for i := 1; i < len(r.Hops); i++ {
		prev, cur := &r.Hops[i-1], &r.Hops[i]
		d := float64(cur.TS.Sub(prev.TS).Microseconds()) / 1000
		cur.DeltaMS = &d
		cur.SameClock = c.Points[prev.Point].Clock == c.Points[cur.Point].Clock
		cur.NAT = prev.Src != cur.Src || prev.Dst != cur.Dst || prev.SrcPort != cur.SrcPort || prev.DstPort != cur.DstPort
	}
	r.Verdict = t.verdict(r.Hops, c)
	return r
}

func rank(p model.Point, h Hop) int {
	switch {
	case contains(p.Owns, h.Src):
		return 0
	case contains(p.Owns, h.Dst):
		return 2
	}
	return 1
}

func label(c Context, id string) string {
	if p, ok := c.Points[id]; ok {
		return p.Label
	}
	return id
}

// covered finds a frame at point carrying the same TCP payload as hop, as
// part of a larger (GRO-merged or not yet TSO-split) segment.
func (t *Tracker) covered(point string, hop Hop) int {
	f := t.Frames[hop.Frame-1]
	if f.Info.Proto != "TCP" || f.Info.SeqLen == 0 {
		return 0
	}
	start, end := f.Info.Seq, f.Info.Seq+f.Info.SeqLen
	// An aggregate holds each byte once: only the first copy of a segment
	// (not its retransmissions) is in it
	for _, n := range t.cover[coverKey{hop.Point, hop.Src, hop.Dst, hop.SrcPort, hop.DstPort}] {
		o := t.Frames[n-1]
		if n >= hop.Frame {
			break
		}
		if o.Info.Seq == start && o.Info.SeqLen == f.Info.SeqLen && f.TS.Sub(o.TS) < Window {
			return 0
		}
	}
	for _, n := range t.cover[coverKey{point, hop.Src, hop.Dst, hop.SrcPort, hop.DstPort}] {
		o := t.Frames[n-1]
		// An aggregate is bigger than what it absorbed; the same size is a
		// retransmission
		if o.TS.Sub(f.TS).Abs() > Window || o.Info.SeqLen <= f.Info.SeqLen {
			continue
		}
		// Sequence arithmetic wraps
		if start-o.Info.Seq < o.Info.SeqLen && end-o.Info.Seq <= o.Info.SeqLen {
			return n
		}
	}
	return 0
}

func (t *Tracker) verdict(hops []Hop, c Context) Verdict {
	last := hops[len(hops)-1]

	if contains(c.Points[last.Point].Owns, last.Dst) {
		return Verdict{Status: Delivered, At: last.Point, Detail: "reached " + label(c, last.Point)}
	}

	seen := map[string]bool{}
	for _, h := range hops {
		seen[h.Point] = true
	}
	recent := c.Running && c.Now.Sub(last.TS) < Window

	// A router that saw the packet come in but not go out dropped it,
	// unless it was addressed to the router.
	for _, h := range hops {
		p := c.Points[h.Point]
		if p.Kind != model.KindRouter || p.Chain != "prerouting" {
			continue
		}
		post := model.RouterPointID(p.Device, "postrouting")
		if seen[post] || !c.Active[post] {
			continue
		}
		if contains(p.Local, h.Dst) {
			return Verdict{Status: Consumed, At: h.Point, Detail: "addressed to " + p.Device}
		}
		if recent {
			return Verdict{Status: InFlight, At: last.Point, Detail: "in flight"}
		}
		return Verdict{Status: Dropped, At: h.Point, Expected: post,
			Detail: fmt.Sprintf("dropped in %s: came in, never went out (firewall, no route, or TTL)", p.Device)}
	}

	// Which capture point is the destination behind?
	var expected []string
	for id := range c.Active {
		if contains(c.Points[id].Owns, last.Dst) {
			expected = append(expected, id)
		}
	}
	slices.Sort(expected)
	for _, id := range expected {
		if seen[id] {
			return Verdict{Status: Delivered, At: id, Detail: "reached " + label(c, id)}
		}
		if n := t.covered(id, last); n > 0 {
			return Verdict{Status: Delivered, At: id, Detail: fmt.Sprintf("reached %s, merged into frame %d (GRO)", label(c, id), n)}
		}
	}
	if recent {
		return Verdict{Status: InFlight, At: last.Point, Detail: "in flight"}
	}
	if len(expected) > 0 {
		return Verdict{Status: Lost, At: last.Point, Expected: expected[0],
			Detail: fmt.Sprintf("lost after %s, never reached %s", label(c, last.Point), label(c, expected[0]))}
	}
	return Verdict{Status: Seen, At: last.Point, Detail: "last seen at " + label(c, last.Point)}
}

type DropSite struct {
	Status   Status `json:"status"`
	At       string `json:"at"`
	Expected string `json:"expected,omitempty"`
	Detail   string `json:"detail"`
	Count    int    `json:"count"`
	// A journey to look at
	Example int `json:"example"`
}

type Latency struct {
	From  string  `json:"from"`
	To    string  `json:"to"`
	Count int     `json:"count"`
	P50   float64 `json:"p50_ms"`
	P95   float64 `json:"p95_ms"`
	Max   float64 `json:"max_ms"`
	// Both points stamp with the same clock; otherwise the numbers include
	// the clock skew between the devices.
	SameClock bool `json:"same_clock"`
}

type Summary struct {
	Frames   int            `json:"frames"`
	Journeys int            `json:"journeys"`
	ByStatus map[Status]int `json:"by_status"`
	Problems []DropSite     `json:"problems"`
	Latency  []Latency      `json:"latency"`
}

func (t *Tracker) Summarize(c Context) Summary {
	s := Summary{Frames: len(t.Frames), Journeys: len(t.Journeys), ByStatus: map[Status]int{}}
	sites := map[string]*DropSite{}
	lat := map[[2]string][]float64{}
	same := map[[2]string]bool{}
	for _, j := range t.Journeys {
		r := t.Analyze(j.ID, c)
		s.ByStatus[r.Verdict.Status]++
		if r.Verdict.Status == Dropped || r.Verdict.Status == Lost {
			key := string(r.Verdict.Status) + "|" + r.Verdict.At + "|" + r.Verdict.Expected
			if sites[key] == nil {
				sites[key] = &DropSite{Status: r.Verdict.Status, At: r.Verdict.At, Expected: r.Verdict.Expected, Detail: r.Verdict.Detail, Example: j.ID}
			}
			sites[key].Count++
		}
		for i := 1; i < len(r.Hops); i++ {
			h := r.Hops[i]
			k := [2]string{r.Hops[i-1].Point, h.Point}
			lat[k] = append(lat[k], *h.DeltaMS)
			same[k] = h.SameClock
		}
	}
	for _, d := range sites {
		s.Problems = append(s.Problems, *d)
	}
	sort.Slice(s.Problems, func(a, b int) bool { return s.Problems[a].Count > s.Problems[b].Count })
	for k, v := range lat {
		slices.Sort(v)
		s.Latency = append(s.Latency, Latency{
			From: k[0], To: k[1], Count: len(v), SameClock: same[k],
			P50: v[len(v)/2], P95: v[min(len(v)-1, len(v)*95/100)], Max: v[len(v)-1],
		})
	}
	sort.Slice(s.Latency, func(a, b int) bool { return s.Latency[a].Count > s.Latency[b].Count })
	return s
}
