package main

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/buildid"
)

// updater restarts the tray into a newly installed version. The signal is the
// daemon's build ID changing: installs (and a future self-updater) replace the
// binaries and then restart the daemon.
type updater struct {
	daemonBuild string // first build seen, then the last one acted on
	ownBuild    string
	path        string
	exec        func(path string) error
}

func newUpdater() *updater {
	return &updater{ownBuild: buildid.Self(), path: launchPath(), exec: reexec}
}

// launchPath is how we were started, not where the binary resolved to: on
// Nix, a profile symlink moves to the new store path while /proc/self/exe
// keeps pointing at the old one.
func launchPath() string {
	arg0 := os.Args[0]
	if filepath.IsAbs(arg0) {
		return arg0
	}
	if p, err := exec.LookPath(arg0); err == nil {
		if abs, err := filepath.Abs(p); err == nil {
			return abs
		}
	}
	exe, _ := os.Executable()
	return exe
}

func reexec(path string) error {
	return syscall.Exec(path, append([]string{path}, os.Args[1:]...), os.Environ())
}

// check looks at a status from the daemon and restarts us if both the daemon
// and our own binary changed. It returns only if no restart happened.
func (u *updater) check(st *api.Status) {
	if st == nil || st.Build == "" {
		return
	}
	if u.daemonBuild == "" || st.Build == u.daemonBuild {
		u.daemonBuild = st.Build
		return
	}
	u.daemonBuild = st.Build
	onDisk := buildid.File(u.path)
	if onDisk == "" || onDisk == u.ownBuild {
		return // daemon changed alone, or the new tray is not readable
	}
	log.Printf("daemon updated to build %s; restarting into tray build %s", st.Build, onDisk)
	if err := u.exec(u.path); err != nil {
		log.Printf("restarting tray: %v", err)
	}
}
