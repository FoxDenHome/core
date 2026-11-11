package journey

import (
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/gopacket/gopacket"
	"github.com/gopacket/gopacket/layers"

	"github.com/FoxDenHome/core/packetfox/internal/model"
)

func tcpPacket(t *testing.T, src, dst string, sport, dport uint16, ttl uint8, id uint16, withEth bool) []byte {
	t.Helper()
	return tcpSeg(t, src, dst, sport, dport, ttl, id, 1000, "hello", withEth)
}

func tcpSeg(t *testing.T, src, dst string, sport, dport uint16, ttl uint8, id uint16, seq uint32, payload string, withEth bool) []byte {
	t.Helper()
	ip := &layers.IPv4{Version: 4, IHL: 5, TTL: ttl, Id: id, Protocol: layers.IPProtocolTCP, SrcIP: net.ParseIP(src), DstIP: net.ParseIP(dst)}
	tcp := &layers.TCP{SrcPort: layers.TCPPort(sport), DstPort: layers.TCPPort(dport), Seq: seq, Ack: 2000, ACK: true, PSH: true, Window: 512}
	_ = tcp.SetNetworkLayerForChecksum(ip)
	buf := gopacket.NewSerializeBuffer()
	opts := gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}
	ls := []gopacket.SerializableLayer{ip, tcp, gopacket.Payload(payload)}
	if withEth {
		eth := &layers.Ethernet{SrcMAC: net.HardwareAddr{2, 0, 0, 0, 0, 1}, DstMAC: net.HardwareAddr{2, 0, 0, 0, 0, 2}, EthernetType: layers.EthernetTypeIPv4}
		ls = append([]gopacket.SerializableLayer{eth}, ls...)
	}
	if err := gopacket.SerializeLayers(buf, opts, ls...); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestFingerprintSurvivesNAT(t *testing.T) {
	a := Parse(layers.LinkTypeEthernet, tcpPacket(t, "10.2.0.5", "1.1.1.1", 40000, 443, 64, 7, true))
	b := Parse(layers.LinkTypeRaw, tcpPacket(t, "203.0.113.1", "1.1.1.1", 51000, 443, 63, 7, false))
	if !a.OK || !b.OK {
		t.Fatal("not parsed")
	}
	if a.Fingerprint != b.Fingerprint {
		t.Error("NAT changed the fingerprint")
	}
	c := Parse(layers.LinkTypeRaw, tcpPacket(t, "10.2.0.5", "1.1.1.1", 40000, 443, 64, 8, false))
	if a.Fingerprint == c.Fingerprint {
		t.Error("different IP IDs share a fingerprint")
	}
}

func TestJourney(t *testing.T) {
	host := netip.MustParseAddr("10.3.0.9")
	points := map[string]model.Point{
		"fennec|-|eth0":         {ID: "fennec|-|eth0", Device: "fennec", Kind: model.KindAgent, Clock: "fennec", Owns: []netip.Addr{netip.MustParseAddr("10.2.0.5")}, Label: "fennec eth0"},
		"router|prerouting":     {ID: "router|prerouting", Device: "router", Kind: model.KindRouter, Chain: "prerouting", Clock: "collector", Label: "router in"},
		"router|postrouting":    {ID: "router|postrouting", Device: "router", Kind: model.KindRouter, Chain: "postrouting", Clock: "collector", Label: "router out"},
		"bengalfox|host-x|eth0": {ID: "bengalfox|host-x|eth0", Device: "bengalfox", Kind: model.KindAgent, Clock: "bengalfox", Owns: []netip.Addr{host}, Label: "x"},
	}
	active := map[string]bool{}
	for id := range points {
		active[id] = true
	}
	c := Context{Points: points, Active: active, Now: time.Unix(100, 0)}

	tr := NewTracker()
	base := time.Unix(10, 0)
	// Delivered: seen at all four points, out of order and with skew
	tr.Add("router|postrouting", base.Add(3*time.Millisecond), Parse(layers.LinkTypeEthernet, tcpPacket(t, "10.2.0.5", "10.3.0.9", 1, 2, 63, 1, true)))
	tr.Add("fennec|-|eth0", base.Add(5*time.Millisecond), Parse(layers.LinkTypeEthernet, tcpPacket(t, "10.2.0.5", "10.3.0.9", 1, 2, 64, 1, true)))
	tr.Add("router|prerouting", base.Add(2*time.Millisecond), Parse(layers.LinkTypeEthernet, tcpPacket(t, "10.2.0.5", "10.3.0.9", 1, 2, 64, 1, true)))
	tr.Add("bengalfox|host-x|eth0", base.Add(4*time.Millisecond), Parse(layers.LinkTypeEthernet, tcpPacket(t, "10.2.0.5", "10.3.0.9", 1, 2, 63, 1, true)))
	// Dropped in the router
	tr.Add("fennec|-|eth0", base, Parse(layers.LinkTypeEthernet, tcpPacket(t, "10.2.0.5", "10.3.0.9", 1, 2, 64, 2, true)))
	tr.Add("router|prerouting", base, Parse(layers.LinkTypeEthernet, tcpPacket(t, "10.2.0.5", "10.3.0.9", 1, 2, 64, 2, true)))
	// Lost after the router
	tr.Add("router|prerouting", base, Parse(layers.LinkTypeEthernet, tcpPacket(t, "10.2.0.5", "10.3.0.9", 1, 2, 64, 3, true)))
	tr.Add("router|postrouting", base, Parse(layers.LinkTypeEthernet, tcpPacket(t, "10.2.0.5", "10.3.0.9", 1, 2, 63, 3, true)))

	if len(tr.Journeys) != 3 {
		t.Fatalf("%d journeys", len(tr.Journeys))
	}
	r := tr.Analyze(1, c)
	want := []string{"fennec|-|eth0", "router|prerouting", "router|postrouting", "bengalfox|host-x|eth0"}
	for i, h := range r.Hops {
		if h.Point != want[i] {
			t.Fatalf("hop order %v", r.Hops)
		}
	}
	if r.Verdict.Status != Delivered {
		t.Errorf("1: %+v", r.Verdict)
	}
	if !r.Hops[2].SameClock || *r.Hops[2].DeltaMS != 1 {
		t.Errorf("router transit %+v", r.Hops[2])
	}
	if v := tr.Analyze(2, c).Verdict; v.Status != Dropped || v.At != "router|prerouting" {
		t.Errorf("2: %+v", v)
	}
	if v := tr.Analyze(3, c).Verdict; v.Status != Lost || v.Expected != "bengalfox|host-x|eth0" {
		t.Errorf("3: %+v", v)
	}

	s := tr.Summarize(c)
	if s.ByStatus[Dropped] != 1 || s.ByStatus[Lost] != 1 || len(s.Problems) != 2 {
		t.Errorf("summary %+v", s)
	}
}

func TestGRO(t *testing.T) {
	host := netip.MustParseAddr("10.3.0.9")
	points := map[string]model.Point{
		"router|postrouting":    {ID: "router|postrouting", Device: "router", Kind: model.KindRouter, Chain: "postrouting", Clock: "collector"},
		"bengalfox|host-x|eth0": {ID: "bengalfox|host-x|eth0", Device: "bengalfox", Kind: model.KindAgent, Clock: "bengalfox", Owns: []netip.Addr{host}},
	}
	c := Context{Points: points, Active: map[string]bool{"router|postrouting": true, "bengalfox|host-x|eth0": true}, Now: time.Unix(100, 0)}
	base := time.Unix(10, 0)
	tr := NewTracker()
	a, b := strings.Repeat("A", 1400), strings.Repeat("B", 1400)
	// Two segments on the wire; the host's GRO merges them into one
	tr.Add("router|postrouting", base, Parse(layers.LinkTypeRaw, tcpSeg(t, "10.2.0.5", "10.3.0.9", 1, 2, 63, 1, 1000, a, false)))
	tr.Add("router|postrouting", base, Parse(layers.LinkTypeRaw, tcpSeg(t, "10.2.0.5", "10.3.0.9", 1, 2, 63, 2, 2400, b, false)))
	tr.Add("bengalfox|host-x|eth0", base, Parse(layers.LinkTypeRaw, tcpSeg(t, "10.2.0.5", "10.3.0.9", 1, 2, 63, 1, 1000, a+b, false)))
	if len(tr.Journeys) != 2 {
		t.Fatalf("%d journeys: the aggregate should join the first segment", len(tr.Journeys))
	}
	if v := tr.Analyze(2, c).Verdict; v.Status != Delivered {
		t.Errorf("second segment: %+v", v)
	}
	// A retransmission the host never got is still lost
	tr.Add("router|postrouting", base, Parse(layers.LinkTypeRaw, tcpSeg(t, "10.2.0.5", "10.3.0.9", 1, 2, 63, 3, 2400, b, false)))
	if v := tr.Analyze(3, c).Verdict; v.Status != Lost {
		t.Errorf("retransmission: %+v", v)
	}
}
