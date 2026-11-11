package sources

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"strconv"
	"strings"
	"time"

	ros "github.com/go-routeros/routeros/v3"

	"github.com/FoxDenHome/core/packetfox/internal/config"
	"github.com/FoxDenHome/core/packetfox/internal/filter"
	"github.com/FoxDenHome/core/packetfox/internal/model"
)

// Comment marks every RouterOS row pfox creates. mikrotik/configure leaves
// rows with this comment alone, and pfox removes all of them when a capture
// ends or pfox starts.
const Comment = "pfox"

var Chains = []string{"prerouting", "postrouting"}

// RouterSource mirrors matching packets with mangle rules (action
// sniff-tzsp), one TZSP port per chain, so the collector knows where each
// packet was seen. Packets in prerouting have not been routed, NATed or
// filtered yet; postrouting sees them on their way out.
type RouterSource struct {
	Router    config.Router
	Password  string
	Collector config.Collector
	// Index of the router, for its TZSP ports.
	Index int
	// Last port any router uses, for excluding TZSP from the capture.
	LastPort int
	Filter   filter.Filter
	Chains   []string
}

func (s *RouterSource) Device() string { return s.Router.Name }

func RouterPort(c config.Collector, index int, chain string) int {
	off := 0
	if chain == "postrouting" {
		off = 1
	}
	return c.BasePort + index*2 + off
}

type rosConn struct{ c *ros.Client }

func dialRouter(ctx context.Context, r config.Router, password string) (*rosConn, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	c, err := ros.DialContext(ctx, r.Address, r.Username, password)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", r.Address, err)
	}
	return &rosConn{c: c}, nil
}

func (c *rosConn) run(ctx context.Context, args ...string) ([]map[string]string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	reply, err := c.c.RunArgsContext(ctx, args)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", args[0], err)
	}
	rows := make([]map[string]string, 0, len(reply.Re))
	for _, s := range reply.Re {
		rows = append(rows, s.Map)
	}
	return rows, nil
}

func (c *rosConn) add(ctx context.Context, path string, attrs map[string]string) error {
	args := []string{path + "/add"}
	for k, v := range attrs {
		args = append(args, "="+k+"="+v)
	}
	_, err := c.run(ctx, args...)
	return err
}

var cleanupPaths = []string{
	"/ip/firewall/mangle",
	"/ipv6/firewall/mangle",
	"/ip/firewall/filter",
	"/ipv6/firewall/filter",
	"/ip/firewall/address-list",
	"/ipv6/firewall/address-list",
}

func (c *rosConn) cleanup(ctx context.Context) error {
	var errs []error
	for _, path := range cleanupPaths {
		rows, err := c.run(ctx, path+"/print", "=.proplist=.id,comment,list,dynamic")
		if err != nil {
			errs = append(errs, err)
			continue
		}
		var ids []string
		for _, r := range rows {
			if r["comment"] == Comment || (strings.HasSuffix(path, "address-list") && r["list"] == filter.AddressList) {
				ids = append(ids, r[".id"])
			}
		}
		if len(ids) == 0 {
			continue
		}
		if _, err := c.run(ctx, path+"/remove", "=.id="+strings.Join(ids, ",")); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// CleanupRouter removes everything a previous pfox left on a router.
func CleanupRouter(ctx context.Context, r config.Router, password string) error {
	c, err := dialRouter(ctx, r, password)
	if err != nil {
		return err
	}
	defer c.c.Close()
	return c.cleanup(ctx)
}

// install adds the address list, the fasttrack bypass and the mirror rules.
// It returns warnings about what could not be mirrored.
func (s *RouterSource) install(ctx context.Context, c *rosConn) ([]string, error) {
	if err := c.cleanup(ctx); err != nil {
		return nil, err
	}
	if len(s.Filter.Hosts) == 0 && len(s.Filter.Ports) == 0 {
		return nil, errors.New("refusing to mirror all of the router's traffic: filter by host or port")
	}
	var installed int
	var warnings []string
	for _, fam := range []string{"ip", "ipv6"} {
		n, err := s.installFamily(ctx, c, fam)
		if err != nil {
			if fam == "ip" {
				return nil, err
			}
			// Mirroring IPv4 alone is still worth it
			warnings = append(warnings, "IPv6 not mirrored: "+err.Error())
			continue
		}
		installed += n
	}
	if installed == 0 {
		return nil, errors.New("the filter matches nothing the router can capture")
	}
	return warnings, nil
}

func (s *RouterSource) installFamily(ctx context.Context, c *rosConn, fam string) (int, error) {
	target := s.Collector.IPv4
	if fam == "ipv6" {
		target = s.Collector.IPv6
	}
	if target == "" {
		return 0, nil
	}
	matchers, ok := s.Filter.RouterMatchers(fam)
	if !ok {
		return 0, nil
	}
	for _, p := range s.Filter.Prefixes() {
		if p.Addr().Is4() != (fam == "ip") {
			continue
		}
		if err := c.add(ctx, "/"+fam+"/firewall/address-list", map[string]string{
			"list": filter.AddressList, "address": p.String(), "comment": Comment,
		}); err != nil {
			return 0, err
		}
	}

	// Keep matching connections off the fast path, which skips mangle.
	// Connections fasttracked before this was added stay invisible until
	// they end.
	fasttrack, err := c.run(ctx, "/"+fam+"/firewall/filter/print", "?chain=forward", "?action=fasttrack-connection", "?dynamic=false", "=.proplist=.id")
	if err != nil {
		return 0, err
	}
	for _, m := range matchers {
		rule := map[string]string{
			"chain": "forward", "action": "accept", "connection-state": "established,related", "comment": Comment,
		}
		for k, v := range m {
			rule[k] = v
		}
		if len(fasttrack) > 0 {
			rule["place-before"] = fasttrack[0][".id"]
		}
		if err := c.add(ctx, "/"+fam+"/firewall/filter", rule); err != nil {
			return 0, err
		}
	}

	var installed int
	for _, chain := range s.Chains {
		if chain == "postrouting" {
			// Don't capture our own TZSP stream
			if err := c.add(ctx, "/"+fam+"/firewall/mangle", map[string]string{
				"chain": "postrouting", "action": "accept", "protocol": "udp",
				"dst-address": target, "dst-port": fmt.Sprintf("%d-%d", s.Collector.BasePort, s.LastPort),
				"comment": Comment,
			}); err != nil {
				return installed, err
			}
		}
		for _, m := range matchers {
			rule := map[string]string{
				"chain": chain, "action": "sniff-tzsp", "sniff-target": target,
				"sniff-target-port": strconv.Itoa(RouterPort(s.Collector, s.Index, chain)),
				"comment":           Comment,
			}
			for k, v := range m {
				rule[k] = v
			}
			if err := c.add(ctx, "/"+fam+"/firewall/mangle", rule); err != nil {
				return installed, err
			}
			installed++
		}
	}
	return installed, nil
}

func (s *RouterSource) Run(ctx context.Context, sink model.Sink, status func(state, msg string)) error {
	var conns []net.PacketConn
	defer func() {
		for _, c := range conns {
			c.Close()
		}
	}()
	for _, chain := range s.Chains {
		port := RouterPort(s.Collector, s.Index, chain)
		pc, err := net.ListenPacket("udp", ":"+strconv.Itoa(port))
		if err != nil {
			return err
		}
		conns = append(conns, pc)
	}

	status("starting", "installing mirror rules")
	c, err := dialRouter(ctx, s.Router, s.Password)
	if err != nil {
		return err
	}
	defer func() {
		// The capture context is done by now
		cctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		err := c.cleanup(cctx)
		c.c.Close()
		if err != nil {
			// Maybe the connection died; one more try on a fresh one
			if err = CleanupRouter(cctx, s.Router, s.Password); err != nil {
				log.Printf("%s: cleanup failed, rows with comment %q remain: %v", s.Router.Name, Comment, err)
			}
		}
	}()
	warnings, err := s.install(ctx, c)
	if err != nil {
		return err
	}
	status("running", strings.Join(append([]string{"mirroring " + strings.Join(s.Chains, " and ") + " via TZSP"}, warnings...), "; "))

	errc := make(chan error, len(conns))
	for i, pc := range conns {
		go func() {
			point := model.RouterPointID(s.Router.Name, s.Chains[i])
			buf := make([]byte, 65536)
			for {
				n, _, err := pc.ReadFrom(buf)
				if err != nil {
					errc <- err
					return
				}
				ts := time.Now()
				lt, payload, err := decodeTZSP(buf[:n])
				if err != nil {
					continue
				}
				data := make([]byte, len(payload))
				copy(data, payload)
				sink(model.Packet{Point: point, TS: ts, LinkType: lt, Data: data, Length: len(data)})
			}
		}()
	}
	select {
	case <-ctx.Done():
		return nil
	case err := <-errc:
		return err
	}
}
