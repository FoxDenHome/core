// foxden-vpnd is the privileged FoxDen VPN daemon, and its tray applet.
//
//	foxden-vpnd            run the daemon (as root)
//	foxden-vpnd tray       run the tray applet (as the desktop user)
//	foxden-vpnd pubkey     print this device's public key
//	foxden-vpnd status     print the daemon's status as JSON
//	foxden-vpnd expose     publish a local port (see `foxden-vpnd expose -h`)
//
// Started as foxden-vpn-tray (a symlink), it runs the tray. Being one
// binary keeps the tray in lock step with the daemon: it restarts into the
// daemon's executable whenever their builds differ.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/buildid"
	"github.com/FoxDenHome/core/vpn/internal/daemon"
	"github.com/FoxDenHome/core/vpn/internal/tray"
	"github.com/FoxDenHome/core/vpn/internal/tunnel"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// Public key of the routers' wg-vpn interface (shared by router and
// router-backup). It authenticates provisioning blobs.
const defaultServerKey = "h+EFbAdOxcqVG1+hglSUam1AaDb2ly80bxBunYGvhWU="

func defaultStateDir() string {
	if runtime.GOOS == "darwin" {
		return "/Library/Application Support/FoxDen VPN"
	}
	return "/var/lib/foxden-vpn"
}

func defaultGroup() string {
	if runtime.GOOS == "darwin" {
		return "admin"
	}
	return "wheel"
}

func main() {
	var (
		stateDir     = flag.String("state-dir", defaultStateDir(), "directory for key, settings and cached provisioning")
		socket       = flag.String("socket", api.DefaultSocket, "control socket path (daemon, tray and commands)")
		group        = flag.String("socket-group", defaultGroup(), "group allowed to use the control socket")
		provisionURL = flag.String("provision-url", "https://cdn.foxden.network/vpn/peers", "base URL of provisioning blobs")
		portalURL    = flag.String("portal-url", "https://portal.foxden.network/", "device registration portal (daemon and tray)")
		serverKey    = flag.String("server-key", defaultServerKey, "WireGuard public key of the VPN server")
		ifname       = flag.String("interface", "foxden0", "interface name (Linux only; macOS assigns utunN)")
		userspace    = flag.Bool("userspace", false, "always use wireguard-go, even if kernel WireGuard is available")
		idle         = flag.Duration("idle-timeout", 5*time.Minute, "drop an idle split-tunnel session after this long")
	)
	flag.Parse()
	if os.Getenv("JOURNAL_STREAM") != "" {
		log.SetFlags(0) // journald adds its own timestamps
	}
	// Hashed now, before an update can replace the file.
	buildid.Self()

	cmd := flag.Arg(0)
	args := os.Args[1:]
	if filepath.Base(os.Args[0]) == "foxden-vpn-tray" && cmd == "" {
		cmd, args = "tray", append(args, "tray")
	}
	switch cmd {
	case "":
	case "tray":
		tray.Run(tray.Options{Socket: *socket, PortalURL: *portalURL, Args: args})
		return
	case "pubkey":
		printPubkey(*stateDir, *socket)
		return
	case "status":
		st, err := api.NewClient(*socket).Status()
		if err != nil {
			log.Fatal(err)
		}
		b, _ := json.MarshalIndent(st, "", "  ")
		fmt.Println(string(b))
		return
	case "expose":
		runExpose(*socket, flag.Args()[1:])
		return
	default:
		log.Fatalf("unknown command %q", flag.Arg(0))
	}

	sk, err := wgtypes.ParseKey(*serverKey)
	if err != nil {
		log.Fatalf("-server-key: %v", err)
	}
	if os.Geteuid() != 0 {
		log.Fatal("foxden-vpnd must run as root")
	}
	tunnel.StateDir = *stateDir

	d, err := daemon.New(daemon.Options{
		StateDir:     *stateDir,
		ProvisionURL: *provisionURL,
		PortalURL:    *portalURL,
		ServerKey:    sk,
		Tunnel:       tunnel.Options{Name: *ifname, ForceUserspace: *userspace},
		IdleTimeout:  *idle,
	})
	if err != nil {
		log.Fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := os.MkdirAll(filepath.Dir(*socket), 0o755); err != nil {
		log.Fatal(err)
	}
	go func() {
		if err := d.Serve(ctx, *socket, *group); err != nil {
			log.Printf("control socket: %v", err)
			stop()
		}
	}()

	if err := d.Run(ctx); err != nil {
		log.Fatal(err)
	}
}

func printPubkey(stateDir, socket string) {
	if st, err := api.NewClient(socket).Status(); err == nil {
		fmt.Println(st.PublicKey)
		return
	}
	b, err := os.ReadFile(filepath.Join(stateDir, "private.key"))
	if err != nil {
		log.Fatalf("daemon not reachable and key not readable: %v", err)
	}
	k, err := wgtypes.ParseKey(strings.TrimSpace(string(b)))
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(k.PublicKey())
}
