package tray

import (
	"fmt"
	"net"
	"strconv"
	"strings"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/expose"
)

// exposeForm is the Expose Local Port dialog: what to publish, how, and
// under which name or port. It is shown again with Error set until what
// was entered is valid or cancelled.
type exposeForm struct {
	Title   string `json:"title"`
	Message string `json:"message"`
	Target  string `json:"target"`
	TCP     bool   `json:"tcp"`
	Name    string `json:"name"` // HTTPS; "" for a random one
	Port    string `json:"port"` // TCP; "" for a random one
	Domain  string `json:"domain"`
	// TCPFirst and TCPLast are the public ports TCP tunnels can ask for;
	// 0 if unknown (a configuration from before they were in it).
	TCPFirst int    `json:"tcp_first"`
	TCPLast  int    `json:"tcp_last"`
	Error    string `json:"error"`

	// process is listening on target, as offered from the menu.
	process, listening string
}

// tcpPorts are well-known ports that do not speak HTTP, so the form offers
// TCP first for them.
var tcpPorts = map[string]bool{
	"22": true, "25": true, "53": true, "445": true, "1883": true, "3306": true, "3389": true,
	"5432": true, "5900": true, "6379": true, "25565": true, "27017": true,
}

// newExposeForm prefills the form for target ("" lets the user type one),
// with the edge's domain and port range from the daemon's status.
func newExposeForm(target, process string, st *api.Status) exposeForm {
	f := exposeForm{Title: exposeTitle, Target: target, process: process, listening: target}
	if st != nil && st.Expose != nil {
		f.Domain = st.Expose.ServerName
		if r := st.Expose.TCPPorts; r != nil && r.First > 0 && r.Last >= r.First {
			f.TCPFirst, f.TCPLast = int(r.First), int(r.Last)
		}
	}
	if target != "" {
		if _, port, err := net.SplitHostPort(target); err == nil {
			f.TCP = tcpPorts[port]
		}
		if process != "" {
			f.Message = process + " is listening on " + target + "."
		}
	} else {
		f.Message = "Publish a port of this machine, or of anything it can reach."
	}
	return f
}

// tunnel turns what was entered into what to publish.
func (f exposeForm) tunnel() (savedTunnel, error) {
	target, err := normalizeTarget(f.Target)
	if err != nil {
		return savedTunnel{}, fmt.Errorf("%q is not a port or host:port", strings.TrimSpace(f.Target))
	}
	s := savedTunnel{Kind: expose.KindHTTP, Target: target}
	if target == f.listening {
		s.Process = f.process
	}
	if f.TCP {
		s.Kind = expose.KindTCP
		if p := strings.TrimSpace(f.Port); p != "" {
			n, err := strconv.Atoi(p)
			if err != nil || n < 1 || n > 65535 {
				return savedTunnel{}, fmt.Errorf("%q is not a port", p)
			}
			if f.TCPFirst > 0 && (n < f.TCPFirst || n > f.TCPLast) {
				return savedTunnel{}, fmt.Errorf("public port %d is outside %s", n, f.tcpRange())
			}
			s.Port = n
		}
		return s, nil
	}
	s.Name = strings.ToLower(strings.TrimSpace(f.Name))
	if s.Name != "" && !expose.ValidName(s.Name) {
		return savedTunnel{}, fmt.Errorf("%q is not a valid name: use up to 32 letters, digits and dashes, not starting or ending with a dash", s.Name)
	}
	return s, nil
}

// tcpRange describes the public ports, as "30000–30199".
func (f exposeForm) tcpRange() string {
	return strconv.Itoa(f.TCPFirst) + "–" + strconv.Itoa(f.TCPLast)
}
