package tray

import (
	"fmt"
	"net"
	"strconv"
	"strings"

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
	Error   string `json:"error"`

	// process is listening on target, as offered from the menu.
	process, listening string
}

// tcpPorts are well-known ports that do not speak HTTP, so the form offers
// TCP first for them.
var tcpPorts = map[string]bool{
	"22": true, "25": true, "53": true, "445": true, "1883": true, "3306": true, "3389": true,
	"5432": true, "5900": true, "6379": true, "25565": true, "27017": true,
}

// newExposeForm prefills the form for target ("" lets the user type one).
func newExposeForm(target, process, domain string) exposeForm {
	f := exposeForm{Title: exposeTitle, Target: target, Domain: domain, process: process, listening: target}
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
