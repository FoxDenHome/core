//go:build !linux && !darwin

package main

// Mounting shares is Linux and macOS only.
type shares struct{}

func newShares(*tray) *shares { return nil }
func (*shares) menu()         {}
func (*shares) run()          {}
func (*shares) poke()         {}
