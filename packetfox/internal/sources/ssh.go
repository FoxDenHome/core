package sources

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gopacket/gopacket/pcapgo"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"

	"github.com/FoxDenHome/core/packetfox/internal/config"
	"github.com/FoxDenHome/core/packetfox/internal/filter"
	"github.com/FoxDenHome/core/packetfox/internal/model"
)

// SSH key algorithms by SSHFP algorithm number
var sshfpAlgos = map[string]string{
	"1": ssh.KeyAlgoRSA,
	"3": ssh.KeyAlgoECDSA256,
	"4": ssh.KeyAlgoED25519,
}

// sshfpMatch reports whether key has a SHA-256 SSHFP record in the repo.
func sshfpMatch(records []string, key ssh.PublicKey) bool {
	sum := sha256.Sum256(key.Marshal())
	fp := hex.EncodeToString(sum[:])
	for _, r := range records {
		f := strings.Fields(r)
		if len(f) == 3 && f[1] == "2" && sshfpAlgos[f[0]] == key.Type() && strings.EqualFold(f[2], fp) {
			return true
		}
	}
	return false
}

// KnownHosts pins host keys on first use, like OpenSSH's
// StrictHostKeyChecking=accept-new. SSHFP records can't be served over the
// network (RouterOS doesn't do SSHFP, and there's no DNSSEC to trust anyway),
// and UniFi regenerates its keys on firmware updates, so the repo's records
// are only a shortcut: a key matching one is accepted without pinning.
type KnownHosts struct {
	Path string
	mu   sync.Mutex
}

func (k *KnownHosts) callback(records []string) ssh.HostKeyCallback {
	return func(hostname string, remote net.Addr, key ssh.PublicKey) error {
		if sshfpMatch(records, key) {
			return nil
		}
		if k == nil {
			return fmt.Errorf("%s: host key %s %s matches no SSHFP record", hostname, key.Type(), ssh.FingerprintSHA256(key))
		}
		k.mu.Lock()
		defer k.mu.Unlock()
		f, err := os.OpenFile(k.Path, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0o600)
		if err != nil {
			return err
		}
		defer f.Close()
		cb, err := knownhosts.New(k.Path)
		if err != nil {
			return err
		}
		err = cb(hostname, remote, key)
		var ke *knownhosts.KeyError
		if err == nil || !errors.As(err, &ke) {
			return err
		}
		if len(ke.Want) > 0 {
			return fmt.Errorf("%s: host key changed to %s %s; if expected, remove its line from %s (line %d)",
				hostname, key.Type(), ssh.FingerprintSHA256(key), k.Path, ke.Want[0].Line)
		}
		if _, err := f.WriteString(knownhosts.Line([]string{knownhosts.Normalize(hostname)}, key) + "\n"); err != nil {
			return err
		}
		log.Printf("%s: pinned new host key %s %s", hostname, key.Type(), ssh.FingerprintSHA256(key))
		return nil
	}
}

// SSHAuth is how pfox logs in to a device.
type SSHAuth struct {
	User     string
	Signer   ssh.Signer
	Password string
	// Where host keys without an SSHFP record are pinned.
	KnownHosts *KnownHosts
}

func LoadSigner(path string) (ssh.Signer, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ssh.ParsePrivateKey(raw)
}

func dialSSH(ctx context.Context, dev config.SSHDevice, auth SSHAuth) (*ssh.Client, error) {
	var methods []ssh.AuthMethod
	if auth.Signer != nil {
		methods = append(methods, ssh.PublicKeys(auth.Signer))
	}
	if auth.Password != "" {
		methods = append(methods, ssh.Password(auth.Password))
	}
	if len(methods) == 0 {
		return nil, fmt.Errorf("%s: no SSH credentials configured", dev.Name)
	}
	user := dev.User
	if user == "" {
		user = auth.User
	}
	cfg := &ssh.ClientConfig{
		User:            user,
		Auth:            methods,
		HostKeyCallback: auth.KnownHosts.callback(dev.SSHFP),
		Timeout:         10 * time.Second,
	}
	addr := dev.Address
	if _, _, err := net.SplitHostPort(addr); err != nil {
		addr = net.JoinHostPort(addr, "22")
	}
	d := net.Dialer{Timeout: 10 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, addr, cfg)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("%s: %w", dev.Name, err)
	}
	return ssh.NewClient(c, chans, reqs), nil
}

func runOutput(c *ssh.Client, cmd string) ([]byte, error) {
	sess, err := c.NewSession()
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	var stderr strings.Builder
	sess.Stderr = &stderr
	out, err := sess.Output(cmd)
	if err != nil {
		return nil, fmt.Errorf("%s: %w: %s", cmd, err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// AgentIface is one interface pfox-agent can capture on.
type AgentIface struct {
	Netns string `json:"netns"`
	Label string `json:"label"`
	Iface string `json:"iface"`
	Kind  string `json:"kind"`
	Up    bool   `json:"up"`
}

// ListPoints asks a device which interfaces it can capture on.
func ListPoints(ctx context.Context, kind model.Kind, dev config.SSHDevice, auth SSHAuth) ([]AgentIface, error) {
	c, err := dialSSH(ctx, dev, auth)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	if kind == model.KindAgent {
		out, err := runOutput(c, "list")
		if err != nil {
			return nil, err
		}
		var ifaces []AgentIface
		if err := json.Unmarshal(out, &ifaces); err != nil {
			return nil, fmt.Errorf("pfox-agent list: %w", err)
		}
		return ifaces, nil
	}
	out, err := runOutput(c, "ls /sys/class/net")
	if err != nil {
		return nil, err
	}
	var ifaces []AgentIface
	for _, name := range strings.Fields(string(out)) {
		if name != "lo" {
			ifaces = append(ifaces, AgentIface{Iface: name, Up: true})
		}
	}
	sort.Slice(ifaces, func(i, j int) bool { return ifaces[i].Iface < ifaces[j].Iface })
	return ifaces, nil
}

// SSHSource runs tcpdump on a device for each of its selected points and
// reads the pcap streams. On NixOS hosts the forced command pfox-agent runs
// it in the right netns; on UniFi APs tcpdump runs directly.
type SSHSource struct {
	Kind    model.Kind
	Dev     config.SSHDevice
	Auth    SSHAuth
	Points  []model.Point
	Filter  filter.Filter
	Snaplen int
}

func (s *SSHSource) Device() string { return s.Dev.Name }

func (s *SSHSource) command(p model.Point) string {
	bpf := s.Filter.BPFExpr()
	if s.Kind == model.KindAgent {
		ns := p.Netns
		if ns == "" {
			ns = "-"
		}
		enc := "-" // an empty word would vanish when sshd splits the command
		if bpf != "" {
			enc = base64.RawURLEncoding.EncodeToString([]byte(bpf))
		}
		return strings.Join([]string{"capture", ns, p.Iface, strconv.Itoa(s.Snaplen), enc}, " ")
	}
	// UniFi firmware: plain tcpdump through the login shell. The interface
	// came from the device itself and the BPF has no quotes (filter.ValidBPF).
	cmd := fmt.Sprintf("exec tcpdump -i %s -n -p -U -s %d -w -", p.Iface, s.Snaplen)
	if bpf != "" {
		cmd += " -- '" + bpf + "'"
	}
	return cmd
}

var ifaceSafe = func(s string) bool {
	if s == "" || len(s) > 15 {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("_.-@", r)) {
			return false
		}
	}
	return true
}

func (s *SSHSource) Run(ctx context.Context, sink model.Sink, status func(state, msg string)) error {
	for _, p := range s.Points {
		if !ifaceSafe(p.Iface) {
			return fmt.Errorf("invalid interface name %q", p.Iface)
		}
	}
	status("starting", "connecting")
	c, err := dialSSH(ctx, s.Dev, s.Auth)
	if err != nil {
		return err
	}
	defer c.Close()

	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		running = map[string]string{}
		errc    = make(chan error, len(s.Points))
		report  = func() {
			var parts []string
			for _, p := range s.Points {
				if m, ok := running[p.ID]; ok {
					parts = append(parts, p.Iface+": "+m)
				}
			}
			status("running", strings.Join(parts, "; "))
		}
	)
	for _, p := range s.Points {
		sess, err := c.NewSession()
		if err != nil {
			return err
		}
		stdout, err := sess.StdoutPipe()
		if err != nil {
			return err
		}
		stderr, err := sess.StderrPipe()
		if err != nil {
			return err
		}
		if err := sess.Start(s.command(p)); err != nil {
			return err
		}
		wg.Add(2)
		go func() {
			defer wg.Done()
			sc := bufio.NewScanner(stderr)
			for sc.Scan() {
				mu.Lock()
				running[p.ID] = strings.TrimSpace(sc.Text())
				report()
				mu.Unlock()
			}
		}()
		go func() {
			defer wg.Done()
			defer sess.Close()
			err := readPcap(stdout, p.ID, sink)
			if ctx.Err() == nil {
				if err == nil || errors.Is(err, io.EOF) {
					err = errors.New("tcpdump exited")
				}
				mu.Lock()
				if m := running[p.ID]; m != "" {
					err = fmt.Errorf("%s: %w (%s)", p.Iface, err, m)
				}
				mu.Unlock()
				errc <- err
			}
		}()
	}
	select {
	case <-ctx.Done():
		c.Close()
		wg.Wait()
		return nil
	case err := <-errc:
		c.Close()
		return err
	}
}

func readPcap(r io.Reader, point string, sink model.Sink) error {
	pr, err := pcapgo.NewReader(r)
	if err != nil {
		return err
	}
	lt := pr.LinkType()
	for {
		data, ci, err := pr.ReadPacketData()
		if err != nil {
			return err
		}
		sink(model.Packet{Point: point, TS: ci.Timestamp, LinkType: lt, Data: data, Length: ci.Length})
	}
}
