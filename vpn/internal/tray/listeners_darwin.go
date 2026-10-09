package tray

import (
	"net/netip"
	"os/exec"
	"strconv"
	"strings"
)

// listenSockets asks lsof for listening TCP sockets. Without root it only
// sees our own processes', which are the ones worth offering anyway.
func listenSockets() ([]listenSocket, error) {
	out, err := exec.Command("lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "cn").Output()
	if err != nil && len(out) == 0 {
		return nil, nil // lsof exits 1 when it finds nothing
	}
	return parseLsof(string(out)), nil
}

// parseLsof parses `lsof -F cn` output: a "c" line with the command name
// per process, then an "n" line per socket, like "*:3000",
// "127.0.0.1:8080" or "[::1]:5432".
func parseLsof(s string) []listenSocket {
	var out []listenSocket
	var comm string
	for _, line := range strings.Split(s, "\n") {
		if line == "" {
			continue
		}
		switch line[0] {
		case 'p':
			comm = ""
		case 'c':
			comm = line[1:]
		case 'n':
			i := strings.LastIndexByte(line, ':')
			if i < 0 {
				continue
			}
			port, err := strconv.Atoi(line[i+1:])
			if err != nil {
				continue
			}
			host := strings.Trim(line[1:i], "[]")
			var addr netip.Addr
			if host == "*" {
				addr = netip.IPv6Unspecified()
			} else if addr, err = netip.ParseAddr(host); err != nil {
				continue
			}
			out = append(out, listenSocket{Addr: addr.Unmap(), Port: port, Process: comm})
		}
	}
	return out
}

// ephemeralPorts returns where the kernel's range for automatically
// assigned ports starts.
func ephemeralPorts() int {
	out, err := exec.Command("sysctl", "-n", "net.inet.ip.portrange.first").Output()
	if err == nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(out))); err == nil {
			return n
		}
	}
	return 49152
}
