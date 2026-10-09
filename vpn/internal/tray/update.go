package tray

import (
	"log"
	"os"
	"syscall"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/buildid"
)

// updater keeps the tray in lock step with the daemon. Both are the same
// binary, so they must have the same build ID; when they do not, the
// daemon was updated (installs replace the binary and restart the daemon)
// and the tray restarts into the daemon's executable.
type updater struct {
	ownBuild string
	args     []string
	exec     func(path string, args []string) error
	// handoff, if set, runs right before the restart; undo runs if the
	// restart failed.
	handoff func() (undo func())
	waiting string // a build whose binary is not in place yet, logged once
	failed  string // a build that could not be started, not tried again
}

func newUpdater(args []string) *updater {
	return &updater{ownBuild: buildid.Self(), args: args, exec: reexec}
}

func reexec(path string, args []string) error {
	return syscall.Exec(path, append([]string{path}, args...), os.Environ())
}

// check looks at a status from the daemon and restarts us into its build
// if ours differs. It returns only if no restart happened; it is called on
// every poll, so a restart that cannot happen yet is retried.
func (u *updater) check(st *api.Status) {
	if st == nil || st.Build == "" || st.Executable == "" || u.ownBuild == "" || st.Build == u.ownBuild {
		return // in step, or a daemon from before lock step
	}
	if st.Build == u.failed {
		return
	}
	// The daemon's file is checked first: during an install it may not be
	// written yet, or a newer one may already be there that the daemon has
	// not been restarted into. Either way, wait for the daemon.
	if onDisk := buildid.File(st.Executable); onDisk != st.Build {
		if u.waiting != st.Build {
			u.waiting = st.Build
			log.Printf("daemon runs build %s, but %s is build %q; waiting", st.Build, st.Executable, onDisk)
		}
		return
	}
	log.Printf("daemon runs build %s; restarting into %s", st.Build, st.Executable)
	undo := func() {}
	if u.handoff != nil {
		undo = u.handoff()
	}
	if err := u.exec(st.Executable, u.args); err != nil {
		log.Printf("restarting tray: %v", err)
		u.failed = st.Build
		undo()
	}
}
