package session

import (
	"context"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/gopacket/gopacket"
	"github.com/gopacket/gopacket/layers"

	"github.com/FoxDenHome/core/packetfox/internal/journey"
	"github.com/FoxDenHome/core/packetfox/internal/model"
)

type fakeSource struct {
	device string
	pkts   []model.Packet
}

func (f *fakeSource) Device() string { return f.device }

func (f *fakeSource) Run(ctx context.Context, sink model.Sink, status func(string, string)) error {
	status("running", "fake")
	for _, p := range f.pkts {
		sink(p)
	}
	<-ctx.Done()
	return nil
}

func udpFrame(t *testing.T, src, dst string, ttl uint8, id uint16, eth bool) []byte {
	t.Helper()
	ip := &layers.IPv4{Version: 4, TTL: ttl, Id: id, Protocol: layers.IPProtocolUDP, SrcIP: net.ParseIP(src), DstIP: net.ParseIP(dst)}
	udp := &layers.UDP{SrcPort: 5353, DstPort: 53}
	_ = udp.SetNetworkLayerForChecksum(ip)
	ls := []gopacket.SerializableLayer{ip, udp, gopacket.Payload("query")}
	if eth {
		ls = append([]gopacket.SerializableLayer{&layers.Ethernet{SrcMAC: net.HardwareAddr{2, 0, 0, 0, 0, 1}, DstMAC: net.HardwareAddr{2, 0, 0, 0, 0, 2}, EthernetType: layers.EthernetTypeIPv4}}, ls...)
	}
	buf := gopacket.NewSerializeBuffer()
	if err := gopacket.SerializeLayers(buf, gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}, ls...); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestSessionEndToEnd(t *testing.T) {
	sharkdBin := os.Getenv("SHARKD")
	if sharkdBin == "" {
		var err error
		if sharkdBin, err = exec.LookPath("sharkd"); err != nil {
			t.Skip("sharkd not found (set SHARKD)")
		}
	}

	dir := filepath.Join(t.TempDir(), "sessions", "20260101-000000")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(filepath.Join(dir, captureFile))
	if err != nil {
		t.Fatal(err)
	}
	points := []model.Point{
		{ID: "router|prerouting", Device: "router", Kind: model.KindRouter, Chain: "prerouting", Clock: "collector", Label: "router › in"},
		{ID: "router|postrouting", Device: "router", Kind: model.KindRouter, Chain: "postrouting", Clock: "collector", Label: "router › out"},
		{ID: "bengalfox|host-dns|eth0", Device: "bengalfox", Kind: model.KindAgent, Clock: "bengalfox", Label: "bengalfox › dns › eth0", Owns: []netip.Addr{netip.MustParseAddr("10.2.0.53")}},
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Session{
		dir: dir, sharkd: sharkdBin, running: true, file: f, ifaces: map[ifaceKey]int{},
		tracker: journey.NewTracker(), cancel: cancel, done: make(chan struct{}),
		meta: Meta{ID: "20260101-000000", Started: time.Now(), Points: points, Snaplen: 65535, MaxPackets: 100, MaxDuration: time.Minute},
	}
	base := time.Now().Add(-10 * time.Second)
	router := &fakeSource{device: "router", pkts: []model.Packet{
		{Point: "router|prerouting", TS: base, LinkType: layers.LinkTypeEthernet, Data: udpFrame(t, "10.3.0.7", "10.2.0.53", 64, 1, true)},
		{Point: "router|postrouting", TS: base.Add(300 * time.Microsecond), LinkType: layers.LinkTypeEthernet, Data: udpFrame(t, "10.3.0.7", "10.2.0.53", 63, 1, true)},
		{Point: "router|prerouting", TS: base.Add(time.Millisecond), LinkType: layers.LinkTypeEthernet, Data: udpFrame(t, "10.3.0.7", "10.2.0.53", 64, 2, true)},
	}}
	host := &fakeSource{device: "bengalfox", pkts: []model.Packet{
		{Point: "bengalfox|host-dns|eth0", TS: base.Add(800 * time.Microsecond), LinkType: layers.LinkTypeRaw, Data: udpFrame(t, "10.3.0.7", "10.2.0.53", 63, 1, false)},
	}}
	for _, src := range []model.Source{router, host} {
		s.meta.Sources = append(s.meta.Sources, &SourceStatus{Device: src.Device()})
	}
	go s.run(ctx, []model.Source{router, host})

	deadline := time.Now().Add(5 * time.Second)
	for s.Flushed() < 4 && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	// Live view, while the file is still open
	rows, err := s.Frames("", 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 4 {
		t.Fatalf("%d rows while live", len(rows))
	}
	s.Stop()

	rows, err = s.Frames("udp", 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 4 || rows[0].Proto != "DNS" && rows[0].Proto != "UDP" {
		t.Fatalf("rows %+v", rows)
	}
	byStatus := map[journey.Status]int{}
	for _, r := range rows {
		byStatus[r.Status]++
	}
	if byStatus[journey.Delivered] != 3 || byStatus[journey.Dropped] != 1 {
		t.Errorf("statuses %v", byStatus)
	}

	d, err := s.Frame(1)
	if err != nil {
		t.Fatal(err)
	}
	if d.Journey == nil || len(d.Journey.Hops) != 3 || d.Journey.Hops[2].Point != "bengalfox|host-dns|eth0" {
		t.Fatalf("journey %+v", d.Journey)
	}
	if len(d.Detail) < 100 {
		t.Errorf("detail %s", d.Detail)
	}
	if err := s.Check("udp &&"); err == nil {
		t.Error("invalid filter accepted")
	}

	// Reopening from disk rebuilds the same journeys
	s.closeIdle(0)
	re, err := open(dir, sharkdBin)
	if err != nil {
		t.Fatal(err)
	}
	sum := re.Summary()
	if sum.Frames != 4 || sum.ByStatus[journey.Dropped] != 1 || len(sum.Problems) != 1 || sum.Problems[0].At != "router|prerouting" {
		t.Errorf("summary after reopen %+v", sum)
	}
	if re.Meta().StopReason != "stopped" {
		t.Errorf("stop reason %q", re.Meta().StopReason)
	}
}
