// Package routeros is a thin wrapper over the RouterOS API (port 8728/8729).
package routeros

import (
	"context"
	"crypto/tls"
	"fmt"
	"time"

	ros "github.com/go-routeros/routeros/v3"
)

type Row = map[string]string

type Router struct {
	Address  string `json:"address"` // host:port
	TLS      bool   `json:"tls"`
	Username string `json:"username"`
	Password string `json:"-"`
}

type Conn struct {
	c *ros.Client
}

func (r Router) Dial(ctx context.Context) (*Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var (
		c   *ros.Client
		err error
	)
	if r.TLS {
		c, err = ros.DialTLSContext(ctx, r.Address, r.Username, r.Password, &tls.Config{})
	} else {
		c, err = ros.DialContext(ctx, r.Address, r.Username, r.Password)
	}
	if err != nil {
		return nil, fmt.Errorf("%s: %w", r.Address, err)
	}
	return &Conn{c: c}, nil
}

func (c *Conn) Close() error { return c.c.Close() }

func attrs(a Row) []string {
	out := make([]string, 0, len(a))
	for k, v := range a {
		out = append(out, "="+k+"="+v)
	}
	return out
}

// Print returns all rows of path matching the given attribute equality query.
func (c *Conn) Print(ctx context.Context, path string, query Row) ([]Row, error) {
	args := []string{path + "/print"}
	for k, v := range query {
		args = append(args, "?"+k+"="+v)
	}
	reply, err := c.c.RunArgsContext(ctx, args)
	if err != nil {
		return nil, fmt.Errorf("%s/print: %w", path, err)
	}
	rows := make([]Row, 0, len(reply.Re))
	for _, s := range reply.Re {
		rows = append(rows, s.Map)
	}
	return rows, nil
}

func (c *Conn) Add(ctx context.Context, path string, a Row) error {
	_, err := c.c.RunArgsContext(ctx, append([]string{path + "/add"}, attrs(a)...))
	if err != nil {
		return fmt.Errorf("%s/add: %w", path, err)
	}
	return nil
}

func (c *Conn) Set(ctx context.Context, path, id string, a Row) error {
	_, err := c.c.RunArgsContext(ctx, append([]string{path + "/set", "=.id=" + id}, attrs(a)...))
	if err != nil {
		return fmt.Errorf("%s/set: %w", path, err)
	}
	return nil
}

func (c *Conn) Remove(ctx context.Context, path, id string) error {
	_, err := c.c.RunArgsContext(ctx, []string{path + "/remove", "=.id=" + id})
	if err != nil {
		return fmt.Errorf("%s/remove: %w", path, err)
	}
	return nil
}
