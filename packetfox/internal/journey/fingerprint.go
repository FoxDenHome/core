// Package journey matches copies of the same packet seen at different
// capture points, orders them into the path the packet took, and works out
// where it went missing.
package journey

import (
	"encoding/binary"
	"hash/fnv"
	"net/netip"

	"github.com/gopacket/gopacket"
	"github.com/gopacket/gopacket/layers"
)

// Info is what the analysis needs from one captured packet.
type Info struct {
	// Fingerprint is the same for every copy of a packet along its path:
	// it skips what routers and NAT rewrite (addresses, ports, TTL,
	// checksums, MSS options) and keeps what they don't.
	Fingerprint uint64
	TTL         uint8
	Src, Dst    netip.Addr
	SrcPort     uint16
	DstPort     uint16
	Proto       string
	// TCP sequence number and payload length (from the headers, so
	// truncation doesn't matter), for matching GRO/TSO aggregates
	Seq    uint32
	SeqLen uint32
	OK     bool
}

// payloadPrefix is how much L4 payload goes into the fingerprint. Capture
// points may truncate differently, so it must stay small.
const payloadPrefix = 64

func Parse(lt layers.LinkType, data []byte) Info {
	pkt := gopacket.NewPacket(data, lt, gopacket.DecodeOptions{Lazy: true, NoCopy: true})
	h := fnv.New64a()
	var info Info
	var b [8]byte
	var ipLen, l4Len int
	put16 := func(v uint16) { binary.BigEndian.PutUint16(b[:2], v); h.Write(b[:2]) }
	put32 := func(v uint32) { binary.BigEndian.PutUint32(b[:4], v); h.Write(b[:4]) }

	if ip4, ok := pkt.Layer(layers.LayerTypeIPv4).(*layers.IPv4); ok {
		info.TTL = ip4.TTL
		info.Src, _ = netip.AddrFromSlice(ip4.SrcIP.To4())
		info.Dst, _ = netip.AddrFromSlice(ip4.DstIP.To4())
		h.Write([]byte{4, byte(ip4.Protocol)})
		put16(ip4.Id)
		put16(ip4.FragOffset)
		ipLen = int(ip4.Length)
		l4Len = int(ip4.Length) - int(ip4.IHL)*4
	} else if ip6, ok := pkt.Layer(layers.LayerTypeIPv6).(*layers.IPv6); ok {
		info.TTL = ip6.HopLimit
		info.Src, _ = netip.AddrFromSlice(ip6.SrcIP)
		info.Dst, _ = netip.AddrFromSlice(ip6.DstIP)
		h.Write([]byte{6, byte(ip6.NextHeader)})
		put32(ip6.FlowLabel)
		ipLen = int(ip6.Length)
		l4Len = int(ip6.Length)
	} else {
		return info
	}
	info.OK = true

	payload := func(p []byte) {
		if len(p) > payloadPrefix {
			p = p[:payloadPrefix]
		}
		h.Write(p)
	}

	switch {
	case pkt.Layer(layers.LayerTypeTCP) != nil:
		tcp := pkt.Layer(layers.LayerTypeTCP).(*layers.TCP)
		info.Proto = "TCP"
		info.SrcPort, info.DstPort = uint16(tcp.SrcPort), uint16(tcp.DstPort)
		put32(tcp.Seq)
		put32(tcp.Ack)
		var flags byte
		for i, f := range []bool{tcp.FIN, tcp.SYN, tcp.RST, tcp.PSH, tcp.ACK, tcp.URG, tcp.ECE, tcp.CWR} {
			if f {
				flags |= 1 << i
			}
		}
		h.Write([]byte{flags})
		put16(tcp.Window)
		payload(tcp.Payload)
		// The IP length is left out: hosts see segments merged by GRO or
		// not yet split by TSO, and those still share the first segment's
		// IP ID, sequence and payload start.
		info.Seq = tcp.Seq
		if n := l4Len - int(tcp.DataOffset)*4; n > 0 {
			info.SeqLen = uint32(n)
		}
	case pkt.Layer(layers.LayerTypeUDP) != nil:
		udp := pkt.Layer(layers.LayerTypeUDP).(*layers.UDP)
		info.Proto = "UDP"
		info.SrcPort, info.DstPort = uint16(udp.SrcPort), uint16(udp.DstPort)
		put16(udp.Length)
		payload(udp.Payload)
	case pkt.Layer(layers.LayerTypeICMPv4) != nil:
		icmp := pkt.Layer(layers.LayerTypeICMPv4).(*layers.ICMPv4)
		info.Proto = "ICMP"
		// NAT rewrites the echo identifier, but not the sequence
		h.Write([]byte{icmp.TypeCode.Type(), icmp.TypeCode.Code()})
		put16(icmp.Seq)
		payload(icmp.Payload)
	case pkt.Layer(layers.LayerTypeICMPv6) != nil:
		icmp := pkt.Layer(layers.LayerTypeICMPv6).(*layers.ICMPv6)
		info.Proto = "ICMPv6"
		h.Write([]byte{icmp.TypeCode.Type(), icmp.TypeCode.Code()})
		payload(icmp.Payload)
	default:
		if app := pkt.ApplicationLayer(); app != nil {
			payload(app.Payload())
		} else if nl := pkt.NetworkLayer(); nl != nil {
			payload(nl.LayerPayload())
		}
	}
	if info.Proto != "TCP" {
		put16(uint16(ipLen))
	}
	info.Fingerprint = h.Sum64()
	return info
}
