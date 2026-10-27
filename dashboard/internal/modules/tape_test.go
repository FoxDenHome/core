package modules

import (
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/FoxDenHome/core/dashboard/internal/flmon"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

// The slots per magazine and their cartridges must match what the library's
// own web UI shows: left magazine 1–11 next to the mail slot, right 12–23.
func TestTapeMagazines(t *testing.T) {
	read := func(name string) string {
		b, err := os.ReadFile("../flmon/testdata/" + name + ".txt")
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	lib := &tapeLibrary{opts: tapeOptions{Drives: 2, Magazines: []int{11, 12}, CleaningUses: 50}}
	st := lib.Skeleton()
	d := &tapeData{status: flmon.ParseStatus(read("stat")), inv: flmon.ParseInventory(read("inv"))}
	lib.fill(&st, &rack.Section{}, d)

	ids := func(g rack.Group) (out []string) {
		for _, s := range g.Slots {
			out = append(out, s.ID)
		}
		return
	}
	if got := ids(st.Faceplate[0]); !slices.Equal(got, []string{"mag0", "mag1", "mail"}) {
		t.Errorf("magazine group = %v", got)
	}
	for _, c := range []struct {
		id, value, first, last string
	}{
		{"mag0", "11/11", "Slot 1", "Slot 11"},
		{"mag1", "12/12", "Slot 12", "Slot 23"},
	} {
		s := st.FindSlot(c.id)
		if s.Value != c.value {
			t.Errorf("%s value = %q, want %q", c.id, s.Value, c.value)
		}
		carts := s.Sections[1].Rows
		if carts[0].Key != c.first || carts[len(carts)-1].Key != c.last {
			t.Errorf("%s holds %s–%s, want %s–%s", c.id, carts[0].Key, carts[len(carts)-1].Key, c.first, c.last)
		}
	}
	for slot, want := range map[string]string{"Slot 1": "P0006SL6", "Slot 11": "P0010SL6", "Slot 12": "P0002SCU", "Slot 23": "P0013SL6"} {
		found := false
		for _, id := range []string{"mag0", "mag1"} {
			for _, r := range st.FindSlot(id).Sections[1].Rows {
				if r.Key == slot {
					found = true
					if !strings.HasPrefix(r.Value, want) {
						t.Errorf("%s = %q, want %s", slot, r.Value, want)
					}
				}
			}
		}
		if !found {
			t.Errorf("%s missing", slot)
		}
	}
	if m := st.FindSlot("mail"); m.Status != rack.StatusEmpty {
		t.Errorf("mail slot = %s, want empty", m.Status)
	}
}
