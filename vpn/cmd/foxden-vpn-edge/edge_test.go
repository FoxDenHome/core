package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/expose"
	"github.com/quic-go/quic-go"
)

const testDomain = "tunnel.test"

type fakeVerifier struct {
	mu      sync.Mutex
	tickets map[string]identity
	revoked map[string]bool
}

func (f *fakeVerifier) Ticket(_ context.Context, ticket string) (identity, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	id, ok := f.tickets[ticket]
	if !ok || f.revoked[id.PublicKey] {
		return identity{}, errors.New("invalid or expired ticket")
	}
	return id, nil
}

func (f *fakeVerifier) Active(_ context.Context, key string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return !f.revoked[key], nil
}

func (f *fakeVerifier) revoke(key string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.revoked[key] = true
}

type harness struct {
	t       *testing.T
	e       *edge
	v       *fakeVerifier
	roots   *x509.CertPool
	tlsLn   net.Listener // direct TLS
	pTLSLn  net.Listener // TLS behind PROXY v2
	httpLn  net.Listener
	ctlAddr string // the control service (QUIC)

	mu       sync.Mutex
	tcpAddrs map[int]string // public port -> where the test listener really is
}

func selfSigned(t *testing.T) (tls.Certificate, *x509.CertPool) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: testDomain},
		DNSNames:              []string{testDomain, "*." + testDomain},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, pool
}

// harnessOption changes the edge before it starts serving.
type harnessOption func(t *testing.T, e *edge)

func withProxies(ps ...string) harnessOption {
	return func(t *testing.T, e *edge) {
		var err error
		if e.proxies, err = parsePrefixes(ps); err != nil {
			t.Fatal(err)
		}
	}
}

func newHarness(t *testing.T, opts ...harnessOption) *harness {
	cert, roots := selfSigned(t)
	cfg := defaultConfig()
	cfg.Domain = testDomain
	cfg.TCPHost = testDomain
	cfg.TCPPorts.First, cfg.TCPPorts.Last = 30000, 30004
	cfg.MaxPerDevice = 2
	cfg.Recheck = "50ms"
	v := &fakeVerifier{
		tickets: map[string]identity{
			"t-alice": {Owner: "alice", Device: "laptop", PublicKey: "key-alice"},
			"t-bob":   {Owner: "bob", Device: "desktop", PublicKey: "key-bob"},
		},
		revoked: map[string]bool{},
	}
	e, err := newEdge(cfg, v, func(*tls.ClientHelloInfo) (*tls.Certificate, error) { return &cert, nil })
	if err != nil {
		t.Fatal(err)
	}
	for _, o := range opts {
		o(t, e)
	}
	h := &harness{t: t, e: e, v: v, roots: roots, tcpAddrs: map[int]string{}}
	e.listen = func(port int) (net.Listener, error) {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err == nil {
			h.mu.Lock()
			h.tcpAddrs[port] = l.Addr().String()
			h.mu.Unlock()
		}
		return l, err
	}
	h.tlsLn = h.serve(func(c net.Conn) { e.serveTLS(c, false) })
	h.pTLSLn = h.serve(func(c net.Conn) { e.serveTLS(c, true) })
	h.httpLn = h.serve(func(c net.Conn) { e.servePlain(c, false) })
	ql, err := quic.ListenAddr("127.0.0.1:0", e.control, expose.QUICConfig(true))
	if err != nil {
		t.Fatal(err)
	}
	h.ctlAddr = ql.Addr().String()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		cancel()
		ql.Close()
	})
	go e.serveQUIC(ctx, ql)
	return h
}

func (h *harness) serve(handle func(net.Conn)) net.Listener {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go handle(c)
		}
	}()
	return l
}

type logSink struct {
	mu    sync.Mutex
	lines []string
}

func (l *logSink) logf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = append(l.lines, fmt.Sprintf(format, args...))
}

func (l *logSink) has(s string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, line := range l.lines {
		if strings.Contains(line, s) {
			return true
		}
	}
	return false
}

// start runs a client and waits for its URL (or its error).
func (h *harness) start(ticket, target string, hello expose.Hello) (url string, logs *logSink, stop func(), err error) {
	ctx, cancel := context.WithCancel(context.Background())
	urls := make(chan string, 4)
	errc := make(chan error, 1)
	logs = &logSink{}
	c := &expose.Client{
		Edges:      []string{h.ctlAddr},
		ServerName: testDomain,
		Target:     target,
		Hello:      hello,
		Ticket: func(context.Context) (expose.Ticket, error) {
			return expose.Ticket{Ticket: ticket}, nil
		},
		TLS:   &tls.Config{RootCAs: h.roots},
		OnURL: func(u string) { urls <- u },
		Logf:  logs.logf,
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		errc <- c.Run(ctx)
	}()
	stop = func() {
		cancel()
		<-done
	}
	select {
	case url = <-urls:
		return url, logs, stop, nil
	case err = <-errc:
		cancel()
		return "", nil, func() {}, err
	case <-time.After(10 * time.Second):
		stop()
		return "", nil, func() {}, errors.New("timeout waiting for the tunnel")
	}
}

// httpsClient talks to the edge's TLS listener l whatever the URL's host.
func (h *harness) httpsClient(l net.Listener, proxyHeader []byte) *http.Client {
	return &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: h.roots},
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer
			c, err := d.DialContext(ctx, network, l.Addr().String())
			if err == nil && proxyHeader != nil {
				_, err = c.Write(proxyHeader)
			}
			return c, err
		},
		DisableKeepAlives: true,
	}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func proxyV4(src string, srcPort uint16) []byte {
	b := append([]byte{}, proxySig...)
	b = append(b, 0x21, 0x11, 0, 12)
	b = append(b, net.ParseIP(src).To4()...)
	b = append(b, 127, 0, 0, 1)
	b = binary.BigEndian.AppendUint16(b, srcPort)
	return binary.BigEndian.AppendUint16(b, 443)
}

func get(t *testing.T, c *http.Client, url string) (int, string) {
	t.Helper()
	resp, err := c.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestHTTPTunnel(t *testing.T) {
	h := newHarness(t)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hello from %s%s", r.Host, r.URL.Path)
	}))
	defer backend.Close()

	url, logs, stop, err := h.start("t-alice", backend.Listener.Addr().String(), expose.Hello{Kind: expose.KindHTTP, Name: "demo"})
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	if url != "https://demo."+testDomain {
		t.Fatalf("url = %q", url)
	}

	code, body := get(t, h.httpsClient(h.tlsLn, nil), url+"/path")
	if code != 200 || body != "hello from demo.tunnel.test/path" {
		t.Fatalf("got %d %q", code, body)
	}

	// Through foxIngress, the client address comes from the PROXY header.
	code, _ = get(t, h.httpsClient(h.pTLSLn, proxyV4("192.0.2.7", 5555)), url+"/")
	if code != 200 {
		t.Fatalf("proxied: got %d", code)
	}
	eventually(t, "the client to log the public address", func() bool { return logs.has("connection from 192.0.2.7:5555") })

	code, _ = get(t, h.httpsClient(h.tlsLn, nil), "https://nope."+testDomain+"/")
	if code != http.StatusNotFound {
		t.Fatalf("unknown name: got %d", code)
	}
	code, body = get(t, h.httpsClient(h.tlsLn, nil), "https://"+testDomain+"/readyz")
	if code != 200 || body != "ok\n" {
		t.Fatalf("apex readyz: got %d %q", code, body)
	}

	// Plain HTTP goes to HTTPS.
	plain := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, _ := http.NewRequest(http.MethodGet, "http://"+h.httpLn.Addr().String()+"/x?y=1", nil)
	req.Host = "demo." + testDomain
	resp, err := plain.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusPermanentRedirect || resp.Header.Get("Location") != "https://demo.tunnel.test/x?y=1" {
		t.Fatalf("redirect: %d %q", resp.StatusCode, resp.Header.Get("Location"))
	}
}

func TestTCPTunnel(t *testing.T) {
	h := newHarness(t)
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			c, err := echo.Accept()
			if err != nil {
				return
			}
			go func() {
				_, _ = io.Copy(c, c)
				_ = c.(*net.TCPConn).CloseWrite()
			}()
		}
	}()

	url, _, stop, err := h.start("t-alice", echo.Addr().String(), expose.Hello{Kind: expose.KindTCP})
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	portStr, ok := strings.CutPrefix(url, "tcp://"+testDomain+":")
	port, _ := strconv.Atoi(portStr)
	if !ok || port < 30000 || port > 30004 {
		t.Fatalf("url = %q", url)
	}

	h.mu.Lock()
	addr := h.tcpAddrs[port]
	h.mu.Unlock()
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, err := c.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	_ = c.(*net.TCPConn).CloseWrite() // half close must travel through
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	b, err := io.ReadAll(c)
	if err != nil || string(b) != "ping" {
		t.Fatalf("echo: %q, %v", b, err)
	}
}

func TestNamesAndLimits(t *testing.T) {
	h := newHarness(t)
	hello := expose.Hello{Kind: expose.KindHTTP, Name: "mine"}
	_, _, stop, err := h.start("t-alice", "127.0.0.1:1", hello)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := h.start("t-bob", "127.0.0.1:1", hello); err == nil || !strings.Contains(err.Error(), "taken") {
		t.Fatalf("bob took alice's name: %v", err)
	}
	if _, _, _, err := h.start("t-nobody", "127.0.0.1:1", hello); err == nil || !strings.Contains(err.Error(), "ticket") {
		t.Fatalf("bad ticket: %v", err)
	}

	// Closed, the name stays with alice for a while.
	stop()
	eventually(t, "the tunnel to close", func() bool { return h.e.lookupName("mine") == nil })
	if _, _, _, err := h.start("t-bob", "127.0.0.1:1", hello); err == nil {
		t.Fatal("bob got alice's held name")
	}
	_, _, stop, err = h.start("t-alice", "127.0.0.1:1", hello)
	if err != nil {
		t.Fatalf("alice did not get her name back: %v", err)
	}
	defer stop()

	_, _, stop2, err := h.start("t-alice", "127.0.0.1:1", expose.Hello{Kind: expose.KindHTTP})
	if err != nil {
		t.Fatal(err)
	}
	defer stop2()
	if _, _, _, err := h.start("t-alice", "127.0.0.1:1", expose.Hello{Kind: expose.KindHTTP}); err == nil || !strings.Contains(err.Error(), "already has 2") {
		t.Fatalf("limit: %v", err)
	}
	if _, _, _, err := h.start("t-bob", "127.0.0.1:1", expose.Hello{Kind: expose.KindHTTP, Name: "-bad"}); err == nil {
		t.Fatal("invalid name accepted")
	}
}

func TestRevokedDeviceLosesTunnel(t *testing.T) {
	h := newHarness(t)
	_, _, stop, err := h.start("t-bob", "127.0.0.1:1", expose.Hello{Kind: expose.KindHTTP, Name: "gone"})
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	h.v.revoke("key-bob")
	eventually(t, "the tunnel to close", func() bool { return h.e.lookupName("gone") == nil })
}

func TestTrustedProxies(t *testing.T) {
	// The test connects from 127.0.0.1, which is not trusted here.
	h := newHarness(t, withProxies("192.0.2.1", "10.2.0.0/23"))
	resp, err := h.httpsClient(h.pTLSLn, proxyV4("192.0.2.7", 5555)).Get("https://" + testDomain + "/readyz")
	if err == nil {
		resp.Body.Close()
		t.Fatal("PROXY header accepted from an untrusted address")
	}
	h = newHarness(t, withProxies("127.0.0.1"))
	if code, _ := get(t, h.httpsClient(h.pTLSLn, proxyV4("192.0.2.7", 5555)), "https://"+testDomain+"/readyz"); code != 200 {
		t.Fatalf("trusted proxy: %d", code)
	}
	if _, err := parsePrefixes([]string{"nope"}); err == nil {
		t.Fatal("parsed garbage")
	}
}

func TestProxyHeaderIPv6(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	go func() {
		hdr := append([]byte{}, proxySig...)
		hdr = append(hdr, 0x21, 0x21, 0, 36)
		hdr = append(hdr, net.ParseIP("2001:db8::1").To16()...)
		hdr = append(hdr, net.ParseIP("2001:db8::2").To16()...)
		hdr = binary.BigEndian.AppendUint16(hdr, 4242)
		hdr = binary.BigEndian.AppendUint16(hdr, 443)
		_, _ = a.Write(append(hdr, "rest"...))
	}()
	c, err := readProxyHeader(b)
	if err != nil {
		t.Fatal(err)
	}
	if got := c.RemoteAddr().String(); got != "[2001:db8::1]:4242" {
		t.Fatalf("remote = %s", got)
	}
	rest, _ := bufio.NewReader(c).Peek(4)
	if string(rest) != "rest" {
		t.Fatalf("payload = %q", rest)
	}

	go func() { _, _ = a.Write([]byte("GET / HTTP/1.1\r\n\r\n")) }()
	if _, err := readProxyHeader(b); err == nil {
		t.Fatal("accepted a connection without a PROXY header")
	}
}
