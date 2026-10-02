//go:build !linux

package main

// Mounting shares is Linux-only for now.
type shares struct{}

func newShares(*tray) *shares { return nil }
func (*shares) menu()         {}
func (*shares) run()          {}
func (*shares) poke()         {}
