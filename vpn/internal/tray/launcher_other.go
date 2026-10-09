//go:build !linux

package tray

import "github.com/FoxDenHome/core/vpn/internal/api"

// The Servers menu is Linux-only for now.
type launcher struct{}

func newLauncher(*tray) *launcher    { return nil }
func (*launcher) menu()              {}
func (*launcher) render(*api.Status) {}
