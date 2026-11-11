// Package model holds the types shared by capture sources, the session and
// the journey analysis.
package model

import (
	"context"
	"net/netip"
	"strings"
	"time"

	"github.com/gopacket/gopacket/layers"
)

type Kind string

const (
	KindRouter Kind = "router"
	KindAgent  Kind = "agent"
	KindAP     Kind = "ap"
)

// Point is one place packets are observed: a router chain, or an interface
// in some netns of a host or AP.
type Point struct {
	ID     string `json:"id"`
	Device string `json:"device"`
	Kind   Kind   `json:"kind"`
	Netns  string `json:"netns,omitempty"`
	Iface  string `json:"iface,omitempty"`
	// What the netns is (its name, or the unit holding it) and what kind
	// of link the interface is (physical, sriov-vf, sriov-pf, macvtap, …)
	NetnsLabel string `json:"netns_label,omitempty"`
	IfKind     string `json:"if_kind,omitempty"`
	Chain      string `json:"chain,omitempty"`
	Label      string `json:"label"`
	// Points with the same clock have comparable timestamps. Router
	// points are stamped on arrival at the collector, so they share one.
	Clock string `json:"clock"`
	// Addresses that live behind this point: a packet to one of them has
	// arrived once it is seen here.
	Owns []netip.Addr `json:"owns,omitempty"`
	// Addresses of the device itself (a router consuming a packet is not
	// dropping it).
	Local []netip.Addr `json:"local,omitempty"`
}

func RouterPointID(router, chain string) string {
	return router + "|" + chain
}

func IfacePointID(device, netns, iface string) string {
	return device + "|" + netns + "|" + iface
}

// SplitPointID returns the device a point ID belongs to.
func PointDevice(id string) string {
	d, _, _ := strings.Cut(id, "|")
	return d
}

type Packet struct {
	Point    string
	TS       time.Time
	LinkType layers.LinkType
	Data     []byte
	// Length on the wire, Data may be truncated
	Length int
}

type Sink func(Packet)

// Source captures on one device. Run blocks until ctx ends or the capture
// fails, reporting progress through status.
type Source interface {
	Device() string
	Run(ctx context.Context, sink Sink, status func(state, msg string)) error
}
