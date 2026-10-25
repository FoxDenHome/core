// Package snmp wraps gosnmp with the few operations the modules need.
package snmp

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/gosnmp/gosnmp"
)

type Client struct {
	g *gosnmp.GoSNMP
}

// Dial opens an SNMPv2c session. Close it after the poll.
func Dial(ctx context.Context, target, community string) (*Client, error) {
	if community == "" {
		// Agents silently drop requests with the wrong community, which would
		// otherwise only show up as a timeout.
		return nil, errors.New("SNMP community is empty (is $SNMP_COMMUNITY set?)")
	}
	timeout := 5 * time.Second
	if dl, ok := ctx.Deadline(); ok {
		timeout = time.Until(dl) / 3
	}
	g := &gosnmp.GoSNMP{
		Target:             target,
		Port:               161,
		Community:          community,
		Version:            gosnmp.Version2c,
		Timeout:            timeout,
		Retries:            1,
		Context:            ctx,
		MaxOids:            gosnmp.MaxOids,
		MaxRepetitions:     25,
		ExponentialTimeout: false,
	}
	if err := g.Connect(); err != nil {
		return nil, err
	}
	return &Client{g: g}, nil
}

func (c *Client) Close() {
	_ = c.g.Conn.Close()
}

// Values maps a full numeric OID (without leading dot) to its value.
type Values map[string]gosnmp.SnmpPDU

func (c *Client) Get(oids ...string) (Values, error) {
	out := Values{}
	for start := 0; start < len(oids); start += gosnmp.MaxOids {
		end := min(start+gosnmp.MaxOids, len(oids))
		pkt, err := c.g.Get(oids[start:end])
		if err != nil {
			return nil, explain(err)
		}
		if pkt.Error != gosnmp.NoError {
			return nil, fmt.Errorf("snmp get: %v", pkt.Error)
		}
		for _, v := range pkt.Variables {
			if v.Type == gosnmp.NoSuchObject || v.Type == gosnmp.NoSuchInstance {
				continue
			}
			out[strings.TrimPrefix(v.Name, ".")] = v
		}
	}
	return out, nil
}

// Column walks a table column and returns its values keyed by row index
// (the OID suffix after root, e.g. "1" or "1.3").
func (c *Client) Column(root string) (map[string]gosnmp.SnmpPDU, error) {
	out := map[string]gosnmp.SnmpPDU{}
	prefix := strings.TrimPrefix(root, ".") + "."
	err := c.g.BulkWalk(root, func(v gosnmp.SnmpPDU) error {
		name := strings.TrimPrefix(v.Name, ".")
		if strings.HasPrefix(name, prefix) {
			out[strings.TrimPrefix(name, prefix)] = v
		}
		return nil
	})
	return out, explain(err)
}

// explain points at the usual culprit: an agent ignores requests with a
// community it doesn't know, so a bad community looks exactly like a timeout.
func explain(err error) error {
	if err != nil && strings.Contains(err.Error(), "timeout") {
		return fmt.Errorf("no SNMP response (wrong community or unreachable): %w", err)
	}
	return err
}

func (v Values) Int(oid string) (int64, bool) {
	pdu, ok := v[oid]
	if !ok {
		return 0, false
	}
	return Int(pdu)
}

func (v Values) String(oid string) string {
	pdu, ok := v[oid]
	if !ok {
		return ""
	}
	return String(pdu)
}

func Int(pdu gosnmp.SnmpPDU) (int64, bool) {
	switch pdu.Type {
	case gosnmp.Integer, gosnmp.Counter32, gosnmp.Gauge32, gosnmp.TimeTicks, gosnmp.Counter64, gosnmp.Uinteger32:
		return gosnmp.ToBigInt(pdu.Value).Int64(), true
	}
	return 0, false
}

// Uint reads counters that may not fit an int64.
func Uint(pdu gosnmp.SnmpPDU) (uint64, bool) {
	switch pdu.Type {
	case gosnmp.Counter32, gosnmp.Gauge32, gosnmp.Counter64, gosnmp.Uinteger32, gosnmp.TimeTicks:
		b := gosnmp.ToBigInt(pdu.Value)
		if b.Sign() < 0 || b.Cmp(new(big.Int).SetUint64(^uint64(0))) > 0 {
			return 0, false
		}
		return b.Uint64(), true
	}
	return 0, false
}

func String(pdu gosnmp.SnmpPDU) string {
	switch val := pdu.Value.(type) {
	case []byte:
		return strings.TrimRight(strings.TrimSpace(string(val)), "\x00")
	case string:
		return strings.TrimSpace(val)
	}
	return fmt.Sprint(pdu.Value)
}
