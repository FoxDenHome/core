//go:build !linux && !darwin

package tray

// Mounting shares is Linux and macOS only.
type shares struct{}

func newShares(*tray) *shares { return nil }
func (*shares) menu()         {}
func (*shares) run()          {}
func (*shares) poke()         {}
