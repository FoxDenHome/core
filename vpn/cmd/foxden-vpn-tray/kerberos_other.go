//go:build !linux && !darwin

package main

// Kerberos tickets are Linux and macOS only.
type kerberos struct{}

func newKerberos(*tray) *kerberos { return nil }
func (*kerberos) run()            {}
func (*kerberos) poke()           {}
