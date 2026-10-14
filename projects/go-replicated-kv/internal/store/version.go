// Package store holds the data of one node: an in-memory map backed by an
// append-only write-ahead log, plus the version and clock types used to
// decide which of two copies of a key is newer.
package store

import (
	"fmt"
	"sync"
	"time"
)

// Version orders writes to the same key. TS comes from a hybrid clock
// (wall-clock microseconds, bumped so it never goes backwards). Node is the
// ID of the node that coordinated the write and breaks ties, so every node
// picks the same winner without talking to the others.
type Version struct {
	TS   uint64 `json:"ts"`
	Node string `json:"node"`
}

// Compare returns -1 if v is older than o, +1 if newer and 0 if equal.
func (v Version) Compare(o Version) int {
	switch {
	case v.TS < o.TS:
		return -1
	case v.TS > o.TS:
		return 1
	case v.Node < o.Node:
		return -1
	case v.Node > o.Node:
		return 1
	}
	return 0
}

// Newer reports whether v should replace o (last writer wins).
func (v Version) Newer(o Version) bool { return v.Compare(o) > 0 }

// IsZero reports whether v was never set.
func (v Version) IsZero() bool { return v.TS == 0 && v.Node == "" }

func (v Version) String() string { return fmt.Sprintf("%d@%s", v.TS, v.Node) }

// Record is one versioned key. A delete is stored as a record with
// Deleted set (a tombstone), so the delete itself can replicate and win
// over older values.
type Record struct {
	Key     string  `json:"key"`
	Value   []byte  `json:"value,omitempty"`
	Version Version `json:"version"`
	Deleted bool    `json:"deleted,omitempty"`
}

// Clock hands out timestamps that are unique and increasing on this node,
// and never lower than any timestamp the node has seen from a peer. It
// follows wall-clock time when it can, so versions from different nodes
// line up roughly with real time.
type Clock struct {
	mu   sync.Mutex
	last uint64
	now  func() time.Time
}

// NewClock returns a clock. now may be nil to use time.Now.
func NewClock(now func() time.Time) *Clock {
	if now == nil {
		now = time.Now
	}
	return &Clock{now: now}
}

// Next returns a timestamp greater than every one returned or observed before.
func (c *Clock) Next() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	phys := uint64(c.now().UnixMicro())
	if phys > c.last {
		c.last = phys
	} else {
		c.last++
	}
	return c.last
}

// Observe moves the clock forward past a timestamp seen from another node.
func (c *Clock) Observe(ts uint64) {
	c.mu.Lock()
	if ts > c.last {
		c.last = ts
	}
	c.mu.Unlock()
}
