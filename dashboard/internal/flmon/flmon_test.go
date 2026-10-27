package flmon

import (
	"os"
	"slices"
	"testing"
	"time"
)

func fixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name + ".txt")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestParseStatus(t *testing.T) {
	st := ParseStatus(fixture(t, "stat"))
	for k, want := range map[string]string{
		"Serial Number":        "L2U78BK968",
		"Firmware Revision":    "6.30",
		"Robotic FW Revision":  "3.60e",
		"Move count":           "387",
		"Robotics Temperature": "38.0",
		"Number of Powerups":   "31",
		"Minutes of Operation": "1585994 (1101d, 9h, 14min)",
		"Ready":                "On",
		"Error":                "Off",
		"Router Assigned Adr.": "2A0E:7D44:F069:A01:20E:11FF:FE14:708B",
	} {
		if got := st.Library[k]; got != want {
			t.Errorf("library %q = %q, want %q", k, got, want)
		}
	}
	if len(st.Drives) != 2 {
		t.Fatalf("got %d drives", len(st.Drives))
	}
	for k, want := range map[string]string{
		"Product ID":          "ULT3580-HH6",
		"Serial number":       "10WT033159",
		"Port A Status":       "Ready",
		"Port A Speed":        "6 Gb/s",
		"Port B Link":         "Not connected",
		"Media loads":         "9332",
		"Cleaning operations": "144",
		"Tape meters":         "41525959",
	} {
		if got := st.Drives[0][k]; got != want {
			t.Errorf("drive 0 %q = %q, want %q", k, got, want)
		}
	}
	if got := st.Drives[1]["Drive Temperature"]; got != "42.0" {
		t.Errorf("drive 1 temperature = %q", got)
	}
}

func TestParseInventory(t *testing.T) {
	inv := ParseInventory(fixture(t, "inv"))
	count := map[string]int{}
	for _, e := range inv.Elements {
		count[e.Kind]++
	}
	if count["Mailslot"] != 1 || count["Slot"] != 23 || count["Drive"] != 2 || count["Transp."] != 1 {
		t.Fatalf("element counts %v", count)
	}
	var slot1, slot12, slot14 Element
	for _, e := range inv.Elements {
		if e.Kind == "Slot" {
			switch e.Number {
			case 1:
				slot1 = e
			case 12:
				slot12 = e
			case 14:
				slot14 = e
			}
		}
	}
	if slot1.Address != 1001 || slot1.Medium != "Data 6" || slot1.Barcode != "P0006SL6" || slot1.Loads != 25 || !slot1.Access || slot1.Exceptions != "" {
		t.Errorf("slot 1 = %+v", slot1)
	}
	if !slot12.Cleaning() || slot12.Loads != 11 {
		t.Errorf("slot 12 = %+v", slot12)
	}
	if slot14.Loads != -1 || slot14.Barcode != "P0018SL6" {
		t.Errorf("slot 14 = %+v", slot14)
	}
	for _, e := range inv.Elements {
		if e.Kind == "Drive" && e.Full() {
			t.Errorf("drive %d should be empty: %+v", e.Number, e)
		}
	}
	if got := inv.Settings["Lib 0 Loader mode"]; got != "Manual, RND" {
		t.Errorf("loader mode = %q", got)
	}
	if got := inv.Settings["Autoclean"]; got != "Disabled" {
		t.Errorf("autoclean = %q", got)
	}
}

func TestTable(t *testing.T) {
	fans := Table(fixture(t, "fst"))
	if got := fans["Drive"][1]; !slices.Equal(got, []string{"7", "On", "auto", "off", "1", "42.0"}) {
		t.Errorf("fan row 1 = %v", got)
	}
	rets := Table(fixture(t, "rets"))
	if len(rets["Slot"]) != 24 || len(rets["Motor"]) != 5 {
		t.Errorf("retry table sections: slots %d motors %d", len(rets["Slot"]), len(rets["Motor"]))
	}
	if got := rets["Transp."][0]; !slices.Equal(got, []string{"1040", "0"}) {
		t.Errorf("transport row = %v", got)
	}
}

func TestParseActivity(t *testing.T) {
	a := ParseActivity(fixture(t, "dra"))
	if a.Activity != "Idle" {
		t.Errorf("activity = %q", a.Activity)
	}
	if !slices.Equal(a.Flags, []string{"UNLD", "COMPR", "DINIT"}) {
		t.Errorf("flags = %v", a.Flags)
	}
}

func TestParseLog(t *testing.T) {
	log := ParseLog(fixture(t, "edp"))
	if len(log) != 3 {
		t.Fatalf("got %d entries", len(log))
	}
	want := time.Date(2026, 7, 18, 19, 48, 14, 0, time.UTC)
	if !log[0].Time.Equal(want) || log[0].Source != "LIB/ERR" || log[0].Message != "HE: drive broken: needs repair" {
		t.Errorf("entry 0 = %+v", log[0])
	}
}
