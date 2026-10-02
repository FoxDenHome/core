//go:build !linux

package main

// Kerberos tickets are Linux-only for now.
type kerberos struct{}

func newKerberos(*tray) *kerberos { return nil }
func (*kerberos) run()            {}
func (*kerberos) poke()           {}
