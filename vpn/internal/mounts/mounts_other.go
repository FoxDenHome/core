//go:build !linux

package mounts

import "context"

type unsupported struct{}

func NewLinux() Mounter { return unsupported{} }

func (unsupported) Mount(context.Context, User, Request) (Mount, error) {
	return Mount{}, ErrUnsupported
}
func (unsupported) Unmount(User, string) error { return ErrUnsupported }
func (unsupported) List(User) ([]Mount, error) { return nil, ErrUnsupported }
