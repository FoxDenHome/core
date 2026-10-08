package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/expose"
	"github.com/quic-go/quic-go"
)

// identity is who a tunnel belongs to, as the portal vouches.
type identity struct {
	Owner     string `json:"owner"`
	Device    string `json:"device"`
	PublicKey string `json:"public_key"`
}

// verifier checks devices with the portal; an interface so tests can fake it.
type verifier interface {
	// Ticket returns the device a ticket was issued to.
	Ticket(ctx context.Context, ticket string) (identity, error)
	// Active reports whether the device is still registered and enabled.
	Active(ctx context.Context, publicKey string) (bool, error)
}

type tunnel struct {
	id   identity
	kind string
	name string // KindHTTP
	port int    // KindTCP
	ln   net.Listener
	conn *quic.Conn // nil until the Welcome is sent
}

// hold keeps a released name or port for its last device for a while, so a
// reconnecting client gets it back.
type hold struct {
	key   string
	until time.Time
}

type edge struct {
	cfg     Config
	reserve time.Duration
	recheck time.Duration
	verify  verifier
	tls     *tls.Config    // public HTTPS
	control *tls.Config    // control service (QUIC)
	proxies []netip.Prefix // may send PROXY headers; empty: anyone
	// listen opens a raw TCP tunnel's public port.
	listen func(port int) (net.Listener, error)

	mu    sync.Mutex
	names map[string]*tunnel
	ports map[int]*tunnel
	held  map[string]hold
	count map[string]int // tunnels per device key
}

func newEdge(cfg Config, v verifier, getCert func(*tls.ClientHelloInfo) (*tls.Certificate, error)) (*edge, error) {
	reserve, err := time.ParseDuration(cfg.Reserve)
	if err != nil {
		return nil, fmt.Errorf("reserve: %w", err)
	}
	recheck, err := time.ParseDuration(cfg.Recheck)
	if err != nil {
		return nil, fmt.Errorf("recheck: %w", err)
	}
	e := &edge{
		cfg:     cfg,
		reserve: reserve,
		recheck: recheck,
		verify:  v,
		listen: func(port int) (net.Listener, error) {
			return net.Listen("tcp", ":"+strconv.Itoa(port))
		},
		names: map[string]*tunnel{},
		ports: map[int]*tunnel{},
		held:  map[string]hold{},
		count: map[string]int{},
	}
	// Tunnels get no ALPN at all: the local service behind them speaks
	// HTTP/1.1 or its own protocol, never h2 over a TLS it does not
	// terminate. The control protocol is only on its own listener.
	e.tls = &tls.Config{GetCertificate: getCert, MinVersion: tls.VersionTLS12}
	e.control = &tls.Config{GetCertificate: getCert, MinVersion: tls.VersionTLS13, NextProtos: []string{expose.ALPN}}
	return e, nil
}

// label returns the tunnel name of host, a direct child of the domain.
func (e *edge) label(host string) (string, bool) {
	name, ok := strings.CutSuffix(strings.ToLower(host), "."+e.cfg.Domain)
	if !ok || !expose.ValidName(name) {
		return "", false
	}
	return name, true
}

func (e *edge) lookupName(name string) *tunnel {
	e.mu.Lock()
	defer e.mu.Unlock()
	if t := e.names[name]; t != nil && t.conn != nil {
		return t
	}
	return nil
}

func (e *edge) available(key, holder string, inUse bool, now time.Time) bool {
	if inUse {
		return false
	}
	h, ok := e.held[key]
	return !ok || now.After(h.until) || h.key == holder
}

const nameAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789"

func randomName() string {
	b := make([]byte, 10)
	for i := range b {
		n, _ := rand.Int(rand.Reader, big.NewInt(int64(len(nameAlphabet))))
		b[i] = nameAlphabet[n.Int64()]
	}
	return string(b)
}

func randomInt(n int) int {
	v, _ := rand.Int(rand.Reader, big.NewInt(int64(n)))
	return int(v.Int64())
}

// allocate reserves a name or port for a new tunnel of id.
func (e *edge) allocate(id identity, h expose.Hello) (*tunnel, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := time.Now()
	for k, v := range e.held {
		if now.After(v.until) {
			delete(e.held, k)
		}
	}
	if e.count[id.PublicKey] >= e.cfg.MaxPerDevice {
		return nil, fmt.Errorf("this device already has %d tunnels open", e.cfg.MaxPerDevice)
	}
	t := &tunnel{id: id, kind: h.Kind}
	switch h.Kind {
	case expose.KindHTTP:
		if h.Name != "" {
			if !expose.ValidName(h.Name) {
				return nil, errors.New("names are 1-32 lowercase letters, digits and dashes")
			}
			if !e.available("name:"+h.Name, id.PublicKey, e.names[h.Name] != nil, now) {
				return nil, fmt.Errorf("%s.%s is taken", h.Name, e.cfg.Domain)
			}
			t.name = h.Name
		} else {
			for range 100 {
				if n := randomName(); e.available("name:"+n, id.PublicKey, e.names[n] != nil, now) {
					t.name = n
					break
				}
			}
			if t.name == "" {
				return nil, errors.New("no free name")
			}
		}
		e.names[t.name] = t
		delete(e.held, "name:"+t.name)
	case expose.KindTCP:
		first, last := e.cfg.TCPPorts.First, e.cfg.TCPPorts.Last
		var candidates []int
		if h.Port != 0 {
			if h.Port < first || h.Port > last {
				return nil, fmt.Errorf("ports are %d-%d", first, last)
			}
			candidates = []int{h.Port}
		} else {
			// Every port once, starting at a random one.
			n := last - first + 1
			start := randomInt(n)
			for i := range n {
				candidates = append(candidates, first+(start+i)%n)
			}
		}
		for _, port := range candidates {
			if !e.available("port:"+strconv.Itoa(port), id.PublicKey, e.ports[port] != nil, now) {
				continue
			}
			ln, err := e.listen(port)
			if err != nil {
				log.Printf("listening on port %d: %v", port, err)
				continue
			}
			t.port, t.ln = port, ln
			break
		}
		if t.ln == nil {
			if h.Port != 0 {
				return nil, fmt.Errorf("port %d is taken", h.Port)
			}
			return nil, errors.New("no free port")
		}
		e.ports[t.port] = t
		delete(e.held, "port:"+strconv.Itoa(t.port))
	default:
		return nil, fmt.Errorf("unknown tunnel kind %q", h.Kind)
	}
	e.count[id.PublicKey]++
	return t, nil
}

func (e *edge) release(t *tunnel) {
	e.mu.Lock()
	defer e.mu.Unlock()
	h := hold{key: t.id.PublicKey, until: time.Now().Add(e.reserve)}
	if t.name != "" {
		delete(e.names, t.name)
		e.held["name:"+t.name] = h
	}
	if t.ln != nil {
		_ = t.ln.Close()
		delete(e.ports, t.port)
		e.held["port:"+strconv.Itoa(t.port)] = h
	}
	if e.count[t.id.PublicKey]--; e.count[t.id.PublicKey] <= 0 {
		delete(e.count, t.id.PublicKey)
	}
}

func (e *edge) url(t *tunnel) string {
	if t.kind == expose.KindHTTP {
		return "https://" + t.name + "." + e.cfg.Domain
	}
	return fmt.Sprintf("tcp://%s:%d", e.cfg.TCPHost, t.port)
}

// serveQUIC accepts control connections.
func (e *edge) serveQUIC(ctx context.Context, l *quic.Listener) {
	for {
		conn, err := l.Accept(ctx)
		if err != nil {
			return
		}
		go e.serveControl(ctx, conn)
	}
}

// serveControl runs one CLI session: the handshake on its control stream,
// then the tunnel until the connection ends.
func (e *edge) serveControl(ctx context.Context, conn *quic.Conn) {
	defer conn.CloseWithError(0, "")
	actx, cancel := context.WithTimeout(ctx, expose.HandshakeTimeout)
	st, err := conn.AcceptStream(actx)
	cancel()
	if err != nil {
		return
	}
	ctl := expose.StreamConn(conn, st)
	remote := conn.RemoteAddr()
	_ = ctl.SetDeadline(time.Now().Add(expose.HandshakeTimeout))
	r := expose.NewReader(ctl)
	var h expose.Hello
	if err := expose.ReadMsg(r, &h); err != nil {
		return
	}
	fail := func(msg string) {
		if expose.WriteMsg(ctl, expose.Welcome{Error: msg}) != nil {
			return
		}
		// Let the client read it before the connection goes: QUIC would
		// drop unread stream data on close.
		_ = expose.CloseWrite(ctl)
		_ = ctl.SetReadDeadline(time.Now().Add(5 * time.Second))
		_, _ = io.Copy(io.Discard, r)
	}

	vctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	id, err := e.verify.Ticket(vctx, h.Ticket)
	cancel()
	if err != nil {
		log.Printf("refused tunnel from %s: %v", remote, err)
		fail(err.Error())
		return
	}
	t, err := e.allocate(id, h)
	if err != nil {
		log.Printf("refused %s tunnel for %s/%s: %v", h.Kind, id.Owner, id.Device, err)
		fail(err.Error())
		return
	}
	defer e.release(t)
	url := e.url(t)
	if err := expose.WriteMsg(ctl, expose.Welcome{URL: url, Name: t.name, Port: t.port}); err != nil {
		return
	}
	// The control stream stays open, unused, for the session's lifetime.
	_ = ctl.SetDeadline(time.Time{})
	e.mu.Lock()
	t.conn = conn
	e.mu.Unlock()

	log.Printf("opened %s for %s/%s", url, id.Owner, id.Device)
	if t.ln != nil {
		go e.acceptTCP(t)
	}
	e.watch(t)
	log.Printf("closed %s of %s/%s", url, id.Owner, id.Device)
}

func addrOf(a net.Addr) (netip.Addr, bool) {
	ap, err := netip.ParseAddrPort(a.String())
	if err != nil {
		return netip.Addr{}, false
	}
	return ap.Addr().Unmap(), true
}

func inPrefixes(a net.Addr, ps []netip.Prefix) bool {
	ip, ok := addrOf(a)
	if !ok {
		return false
	}
	for _, p := range ps {
		if p.Contains(ip) {
			return true
		}
	}
	return false
}

// watch returns when the session ends or the device is no longer
// registered, so removing a device closes its tunnels too.
func (e *edge) watch(t *tunnel) {
	tick := time.NewTicker(e.recheck)
	defer tick.Stop()
	for {
		select {
		case <-t.conn.Context().Done():
			return
		case <-tick.C:
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		ok, err := e.verify.Active(ctx, t.id.PublicKey)
		cancel()
		switch {
		case err != nil:
			log.Printf("rechecking %s/%s: %v", t.id.Owner, t.id.Device, err) // keep it up while the portal is down
		case !ok:
			log.Printf("%s/%s is no longer registered", t.id.Owner, t.id.Device)
			return
		}
	}
}

func (e *edge) acceptTCP(t *tunnel) {
	for {
		c, err := t.ln.Accept()
		if err != nil {
			return
		}
		go e.forward(t, c)
	}
}

// forward hands a public connection to the device.
func (e *edge) forward(t *tunnel, c net.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	qs, err := t.conn.OpenStreamSync(ctx)
	cancel()
	if err != nil {
		_ = c.Close()
		return
	}
	st := expose.StreamConn(t.conn, qs)
	if err := expose.WriteMsg(st, expose.StreamHeader{Remote: c.RemoteAddr().String()}); err != nil {
		_ = c.Close()
		_ = st.Close()
		return
	}
	expose.Pipe(c, st)
}

// trusted reports whether a PROXY header from c may be believed.
func (e *edge) trusted(c net.Conn) bool {
	return len(e.proxies) == 0 || inPrefixes(c.RemoteAddr(), e.proxies)
}

// accept wraps a listener's connections: PROXY header first if proxied.
func (e *edge) accept(c net.Conn, proxied bool) (net.Conn, bool) {
	if !proxied {
		return c, true
	}
	if !e.trusted(c) {
		_ = c.Close()
		return nil, false
	}
	_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
	pc, err := readProxyHeader(c)
	if err != nil {
		_ = c.Close()
		return nil, false
	}
	_ = c.SetReadDeadline(time.Time{})
	return pc, true
}

func (e *edge) serveTLS(raw net.Conn, proxied bool) {
	c, ok := e.accept(raw, proxied)
	if !ok {
		return
	}
	tc := tls.Server(c, e.tls)
	_ = tc.SetDeadline(time.Now().Add(15 * time.Second))
	if err := tc.Handshake(); err != nil {
		_ = tc.Close()
		return
	}
	_ = tc.SetDeadline(time.Time{})
	sni := strings.ToLower(tc.ConnectionState().ServerName)
	switch {
	case sni == e.cfg.Domain:
		serveHTTP(tc, e.apex)
	default:
		var t *tunnel
		if name, ok := e.label(sni); ok {
			t = e.lookupName(name)
		}
		if t == nil {
			serveHTTP(tc, func(*http.Request) (int, string, http.Header) {
				return http.StatusNotFound, "There is no tunnel at this address.\n", nil
			})
			return
		}
		e.forward(t, tc)
	}
}

func (e *edge) apex(r *http.Request) (int, string, http.Header) {
	if r.URL.Path == "/readyz" {
		return http.StatusOK, "ok\n", nil
	}
	return http.StatusOK, "FoxDen tunnel edge. Publish a local port with `foxden-vpnd expose`.\n", nil
}

// servePlain answers plain HTTP by sending it to HTTPS.
func (e *edge) servePlain(raw net.Conn, proxied bool) {
	c, ok := e.accept(raw, proxied)
	if !ok {
		return
	}
	serveHTTP(c, func(r *http.Request) (int, string, http.Header) {
		host := strings.ToLower(r.Host)
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		_, isTunnel := e.label(host)
		switch {
		case host == e.cfg.Domain && r.URL.Path == "/readyz":
			return http.StatusOK, "ok\n", nil
		case host == e.cfg.Domain || isTunnel:
			target := "https://" + host + r.URL.RequestURI()
			return http.StatusPermanentRedirect, "Moved to " + target + "\n", http.Header{"Location": {target}}
		default:
			return http.StatusNotFound, "Unknown host.\n", nil
		}
	})
}

// serveHTTP answers a single request on c and closes it.
func serveHTTP(c net.Conn, handle func(*http.Request) (int, string, http.Header)) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	req, err := http.ReadRequest(bufio.NewReader(c))
	if err != nil {
		return
	}
	code, body, hdr := handle(req)
	resp := &http.Response{
		StatusCode:    code,
		ProtoMajor:    1,
		ProtoMinor:    1,
		Header:        http.Header{"Content-Type": {"text/plain; charset=utf-8"}},
		ContentLength: int64(len(body)),
		Body:          http.NoBody,
		Close:         true,
		Request:       req,
	}
	for k, v := range hdr {
		resp.Header[k] = v
	}
	if req.Method != http.MethodHead {
		resp.Body = readCloser{strings.NewReader(body)}
	}
	_ = resp.Write(c)
}

type readCloser struct{ *strings.Reader }

func (readCloser) Close() error { return nil }

// certFile serves a certificate from disk, picking up renewals.
type certFile struct {
	cert, key string

	mu      sync.Mutex
	cur     *tls.Certificate
	mod     time.Time
	checked time.Time
}

func (f *certFile) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.cur == nil || time.Since(f.checked) > time.Minute {
		f.checked = time.Now()
		st, err := os.Stat(f.cert)
		if err == nil && (f.cur == nil || !st.ModTime().Equal(f.mod)) {
			c, err := tls.LoadX509KeyPair(f.cert, f.key)
			if err != nil {
				log.Printf("loading certificate: %v", err)
			} else {
				f.cur, f.mod = &c, st.ModTime()
				log.Printf("loaded certificate %s", f.cert)
			}
		} else if err != nil {
			log.Printf("certificate: %v", err)
		}
	}
	if f.cur == nil {
		return nil, errors.New("no certificate")
	}
	return f.cur, nil
}
