package modules

import (
	"slices"
	"strings"
	"testing"

	"github.com/FoxDenHome/core/dashboard/internal/promtext"
)

func TestExpand(t *testing.T) {
	cases := map[string][]string{
		"0/{1..3}":            {"0/1", "0/2", "0/3"},
		"sfp{1..2},wan":       {"sfp1", "sfp2", "wan"},
		"oob":                 {"oob"},
		"{3..1}":              {"3", "2", "1"},
		"a{x,y}b":             {"axb", "ayb"},
		"eth{1..2}-{a,b}":     {"eth1-a", "eth1-b", "eth2-a", "eth2-b"},
		"vlan-mgmt, sfpx2 ":   {"vlan-mgmt", "sfpx2"},
		"":                    nil,
		"#{1..2}":             {"#1", "#2"},
		"sfp-sfpplus{11..12}": {"sfp-sfpplus11", "sfp-sfpplus12"},
	}
	for in, want := range cases {
		if got := expand(in); !slices.Equal(got, want) {
			t.Errorf("expand(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDiskMatches(t *testing.T) {
	d := disk{dev: "sdc", serial: "00017JMJ", wwn: "0x5000c500744669ed", phy: 0}
	for key, want := range map[string]bool{
		"phy:0":                  true,
		"phy:1":                  false,
		"serial:00017jmj":        true,
		"dev:sdc":                true,
		"wwn:0x5000C500744669ED": true,
		"":                       false,
	} {
		if got := d.matches(key); got != want {
			t.Errorf("matches(%q) = %v, want %v", key, got, want)
		}
	}
}

func TestSmartDevice(t *testing.T) {
	smart, err := promtext.Parse(strings.NewReader(`smartctl_device{device="sda",serial_number="AAA"} 1
smartctl_device{device="nvme0",serial_number="S59CNZFNB03251F"} 1
`))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		d    disk
		want string
	}{
		{disk{dev: "sda", serial: "AAA"}, "sda"},
		{disk{dev: "nvme0n1", serial: "S59CNZFNB03251F"}, "nvme0"},
		{disk{dev: "sdq", serial: "ZZZ"}, ""},
	} {
		if got := smartDevice(&c.d, smart); got != c.want {
			t.Errorf("smartDevice(%s) = %q, want %q", c.d.dev, got, c.want)
		}
	}
}

func TestGrowth(t *testing.T) {
	s := &server{}
	for i, c := range []struct{ v, want float64 }{
		{34, 0}, // first sight is the baseline
		{34, 0},
		{36, 2},
		{36, 2}, // stays flagged until a restart
		{0, 0},  // counter reset (drive swapped) starts over
	} {
		if got := s.growth("serial/CRC errors", c.v); got != c.want {
			t.Errorf("step %d: growth(%v) = %v, want %v", i, c.v, got, c.want)
		}
	}
}
