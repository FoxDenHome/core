package daemon

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"net"
	"net/netip"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// queryDNS asks server directly for host's A and AAAA records. Unlike
// net.Resolver it never consults /etc/hosts, so it reports what that server
// really says. If iface is set the query is pinned to that interface and can
// never detour through our own tunnel.
func queryDNS(ctx context.Context, server netip.AddrPort, iface, host string, timeout time.Duration) []netip.Addr {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	name, err := dnsmessage.NewName(strings.TrimSuffix(host, ".") + ".")
	if err != nil {
		return nil
	}
	d := net.Dialer{}
	if iface != "" {
		d.Control = bindToInterface(iface)
	}
	network := "udp4"
	if server.Addr().Is6() {
		network = "udp6"
	}
	conn, err := d.DialContext(ctx, network, server.String())
	if err != nil {
		return nil
	}
	defer conn.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}

	pending := map[uint16]bool{}
	for _, t := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
		var idb [2]byte
		_, _ = rand.Read(idb[:])
		id := binary.BigEndian.Uint16(idb[:])
		msg := dnsmessage.Message{
			Header:    dnsmessage.Header{ID: id, RecursionDesired: true},
			Questions: []dnsmessage.Question{{Name: name, Type: t, Class: dnsmessage.ClassINET}},
		}
		b, err := msg.Pack()
		if err != nil {
			return nil
		}
		if _, err := conn.Write(b); err != nil {
			return nil
		}
		pending[id] = true
	}

	var out []netip.Addr
	buf := make([]byte, 1500)
	for len(pending) > 0 {
		n, err := conn.Read(buf)
		if err != nil {
			break
		}
		var msg dnsmessage.Message
		if msg.Unpack(buf[:n]) != nil || !msg.Response || !pending[msg.ID] {
			continue
		}
		delete(pending, msg.ID)
		for _, a := range msg.Answers {
			switch r := a.Body.(type) {
			case *dnsmessage.AResource:
				out = append(out, netip.AddrFrom4(r.A))
			case *dnsmessage.AAAAResource:
				out = append(out, netip.AddrFrom16(r.AAAA).Unmap())
			}
		}
	}
	return out
}
