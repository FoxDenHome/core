// Package rack holds the data model the modules produce and the UI renders.
package rack

import "time"

type Status string

const (
	StatusOK      Status = "ok"
	StatusWarn    Status = "warn"
	StatusCrit    Status = "crit"
	StatusUnknown Status = "unknown"
	// StatusOff is a slot that is intentionally inactive (link down, outlet off).
	StatusOff Status = "off"
	// StatusEmpty is a slot with nothing in it (empty drive bay, missing port).
	StatusEmpty Status = "empty"
)

var severity = map[Status]int{
	StatusEmpty:   0,
	StatusOff:     0,
	StatusOK:      1,
	StatusUnknown: 2,
	StatusWarn:    3,
	StatusCrit:    4,
}

// Worst returns the most severe status. Off and empty never win over anything else.
func Worst(statuses ...Status) Status {
	worst := StatusOK
	for _, s := range statuses {
		if severity[s] > severity[worst] {
			worst = s
		}
	}
	return worst
}

// State is everything the UI knows about one device.
type State struct {
	Status  Status    `json:"status"`
	Summary string    `json:"summary,omitempty"`
	Error   string    `json:"error,omitempty"`
	Updated time.Time `json:"updated"`
	// Passive devices have nothing to monitor (blanks, brush panels, shelves).
	Passive bool `json:"passive,omitempty"`

	Faceplate []Group   `json:"faceplate,omitempty"`
	Sections  []Section `json:"sections,omitempty"`
}

// GroupKind tells the UI how to draw a group of slots.
type GroupKind string

const (
	KindBay    GroupKind = "bay"
	KindPort   GroupKind = "port"
	KindOutlet GroupKind = "outlet"
	KindMeter  GroupKind = "meter"
	KindLED    GroupKind = "led"
)

// Group is a block of identical slots on the front of a device, laid out in a
// grid of Rows rows filled row by row from the top left.
type Group struct {
	ID    string    `json:"id"`
	Kind  GroupKind `json:"kind"`
	Label string    `json:"label,omitempty"`
	Rows  int       `json:"rows"`
	Slots []Slot    `json:"slots"`
	// Internal groups aren't visible from the front, so the rack view skips
	// them; they still count toward status and show in the details.
	Internal bool `json:"internal,omitempty"`
}

type Slot struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Status Status `json:"status"`
	// Value is a short reading shown on the slot itself ("34°C", "12 W", "10G").
	Value string `json:"value,omitempty"`
	// Percent fills meters.
	Percent  *float64  `json:"percent,omitempty"`
	Sections []Section `json:"sections,omitempty"`
}

type Section struct {
	Title string `json:"title"`
	Rows  []Row  `json:"rows"`
}

type Row struct {
	Key    string `json:"k"`
	Value  string `json:"v"`
	Status Status `json:"s,omitempty"`
}

func (s *Section) Add(key, value string) {
	s.Rows = append(s.Rows, Row{Key: key, Value: value})
}

func (s *Section) AddStatus(key, value string, status Status) {
	s.Rows = append(s.Rows, Row{Key: key, Value: value, Status: status})
}

// Rollup sets the state's status to the worst of its own and all its slots.
func (st *State) Rollup() {
	all := []Status{st.Status}
	for _, g := range st.Faceplate {
		for _, s := range g.Slots {
			all = append(all, s.Status)
		}
	}
	st.Status = Worst(all...)
}

func Percent(v float64) *float64 {
	return &v
}
