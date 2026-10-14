package cluster

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/metrics"
	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/store"
)

// ErrNoQuorum means too few replicas answered in time. For a write it
// means the outcome is unknown: some replicas may have stored the value.
var ErrNoQuorum = errors.New("quorum not reached")

// Config sets the replication parameters.
type Config struct {
	NodeID string
	// W and R are how many replicas (this node included) must answer a
	// write or a read. With N replicas, W+R > N means every read quorum
	// overlaps every write quorum.
	W, R int
	// Timeout bounds every call to a peer.
	Timeout time.Duration
}

// Metrics are the counters the coordinator updates.
type Metrics struct {
	ReplicationFailures *metrics.CounterVec // peer, op
	QuorumFailures      *metrics.CounterVec // op
	ReadRepairs         *metrics.CounterVec // target
	AntiEntropyRepairs  *metrics.CounterVec
	AntiEntropyRuns     *metrics.CounterVec // result
	PeerUp              *metrics.GaugeVec   // peer
}

// NewMetrics registers the coordinator metrics.
func NewMetrics(r *metrics.Registry) *Metrics {
	m := &Metrics{
		ReplicationFailures: r.NewCounterVec("kv_replication_failures_total", "Calls to a peer that failed or timed out.", "peer", "op"),
		QuorumFailures:      r.NewCounterVec("kv_quorum_failures_total", "Client operations that could not reach a quorum.", "op"),
		ReadRepairs:         r.NewCounterVec("kv_read_repairs_total", "Stale or missing replicas fixed during a read.", "target"),
		AntiEntropyRepairs:  r.NewCounterVec("kv_antientropy_repaired_keys_total", "Keys pulled from a peer by anti-entropy."),
		AntiEntropyRuns:     r.NewCounterVec("kv_antientropy_runs_total", "Anti-entropy passes against one peer, by result.", "result"),
		PeerUp:              r.NewGaugeVec("kv_peer_up", "1 if the last ping to the peer succeeded.", "peer"),
	}
	for _, op := range []string{"put", "get", "delete"} {
		m.QuorumFailures.Add(0, op)
	}
	return m
}

// Coordinator runs client operations against the replicas. Any node can
// coordinate any request; there is no leader.
type Coordinator struct {
	cfg   Config
	store *store.Store
	clock *store.Clock
	peers []Peer
	m     *Metrics
	log   *slog.Logger

	reachable atomic.Int64 // peers that answered the last ping
	bg        sync.WaitGroup
}

// NewCoordinator checks the config and returns a coordinator.
func NewCoordinator(cfg Config, st *store.Store, clock *store.Clock, peers []Peer, m *Metrics, log *slog.Logger) (*Coordinator, error) {
	n := len(peers) + 1
	if cfg.W < 1 || cfg.W > n || cfg.R < 1 || cfg.R > n {
		return nil, fmt.Errorf("W=%d and R=%d must be between 1 and N=%d", cfg.W, cfg.R, n)
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 500 * time.Millisecond
	}
	if log == nil {
		log = slog.Default()
	}
	return &Coordinator{cfg: cfg, store: st, clock: clock, peers: peers, m: m, log: log}, nil
}

// Wait blocks until background replication and repair calls finish.
func (c *Coordinator) Wait() { c.bg.Wait() }

// N is the replication factor (every node holds every key).
func (c *Coordinator) N() int { return len(c.peers) + 1 }

// Put writes key=value and returns its version once W replicas have it.
func (c *Coordinator) Put(ctx context.Context, key string, value []byte) (store.Version, error) {
	return c.write(ctx, "put", store.Record{Key: key, Value: value})
}

// Delete writes a tombstone for key.
func (c *Coordinator) Delete(ctx context.Context, key string) (store.Version, error) {
	return c.write(ctx, "delete", store.Record{Key: key, Deleted: true})
}

func (c *Coordinator) write(ctx context.Context, op string, rec store.Record) (store.Version, error) {
	rec.Version = store.Version{TS: c.clock.Next(), Node: c.cfg.NodeID}
	if _, err := c.store.Apply(rec); err != nil {
		return rec.Version, fmt.Errorf("local write: %w", err)
	}
	acks := 1
	if acks >= c.cfg.W && len(c.peers) == 0 {
		return rec.Version, nil
	}

	// Send to every peer, wait for W-1 of them. The rest keep going in
	// the background (bounded by the timeout) so all replicas converge.
	// The calls are detached from the client's context: a client that
	// hangs up must not leave a half-replicated write behind.
	results := make(chan error, len(c.peers))
	rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), c.cfg.Timeout)
	c.fanOut(cancel, func(p Peer) {
		err := p.Replicate(rctx, rec)
		if err != nil {
			c.m.ReplicationFailures.Inc(p.ID(), "replicate")
			c.log.Debug("replicate failed", "peer", p.ID(), "key", rec.Key, "err", err)
		}
		results <- err
	})

	for pending := len(c.peers); pending > 0 && acks < c.cfg.W; pending-- {
		select {
		case err := <-results:
			if err == nil {
				acks++
			}
		case <-ctx.Done():
			return rec.Version, ctx.Err()
		}
	}
	if acks < c.cfg.W {
		c.m.QuorumFailures.Inc(op)
		return rec.Version, fmt.Errorf("%w: %d of %d replicas acknowledged, need %d", ErrNoQuorum, acks, c.N(), c.cfg.W)
	}
	return rec.Version, nil
}

// fanOut runs call once per peer in its own goroutine and calls done
// when all of them have returned.
func (c *Coordinator) fanOut(done func(), call func(Peer)) {
	var wg sync.WaitGroup
	for _, p := range c.peers {
		wg.Add(1)
		c.bg.Add(1)
		go func() {
			defer c.bg.Done()
			defer wg.Done()
			call(p)
		}()
	}
	c.bg.Add(1)
	go func() {
		defer c.bg.Done()
		wg.Wait()
		done()
	}()
}

type readResult struct {
	peer  Peer // nil for the local replica
	rec   store.Record
	found bool
	err   error
}

// Get reads key from R replicas and returns the newest copy. found is
// false if no replica has the key or the newest copy is a tombstone.
// Replicas that answered with an older copy are repaired in the background.
func (c *Coordinator) Get(ctx context.Context, key string) (store.Record, bool, error) {
	local, ok := c.store.Get(key)
	got := []readResult{{rec: local, found: ok}}

	results := make(chan readResult, len(c.peers))
	pending := len(c.peers)
	if len(got) < c.cfg.R {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), c.cfg.Timeout)
		c.fanOut(cancel, func(p Peer) {
			rec, found, err := p.Fetch(rctx, key)
			if err != nil {
				c.m.ReplicationFailures.Inc(p.ID(), "fetch")
			}
			results <- readResult{peer: p, rec: rec, found: found, err: err}
		})
	} else {
		pending = 0 // R=1: the local copy is enough, do not ask peers
	}

	for len(got) < c.cfg.R && pending > 0 {
		select {
		case res := <-results:
			pending--
			if res.err == nil {
				got = append(got, res)
			}
		case <-ctx.Done():
			return store.Record{}, false, ctx.Err()
		}
	}
	if len(got) < c.cfg.R {
		c.m.QuorumFailures.Inc("get")
		return store.Record{}, false, fmt.Errorf("%w: %d of %d replicas answered, need %d", ErrNoQuorum, len(got), c.N(), c.cfg.R)
	}

	var newest store.Record
	found := false
	for _, r := range got {
		if r.found && (!found || r.rec.Version.Newer(newest.Version)) {
			newest, found = r.rec, true
		}
	}
	if found {
		c.clock.Observe(newest.Version.TS)
		// Repair the replicas that answered with an older copy, then any
		// late answers that arrive after we have replied to the client.
		c.bg.Add(1)
		go func() {
			defer c.bg.Done()
			for _, r := range got {
				c.repair(newest, r)
			}
			for range pending {
				if r := <-results; r.err == nil {
					c.repair(newest, r)
				}
			}
		}()
	}
	if !found || newest.Deleted {
		return newest, false, nil
	}
	return newest, true, nil
}

// repair sends newest to a replica whose copy is missing or older.
func (c *Coordinator) repair(newest store.Record, r readResult) {
	if r.found && !newest.Version.Newer(r.rec.Version) {
		return
	}
	if r.peer == nil {
		if applied, err := c.store.Apply(newest); err != nil {
			c.log.Warn("local read repair failed", "key", newest.Key, "err", err)
		} else if applied {
			c.m.ReadRepairs.Inc("local")
		}
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.Timeout)
	defer cancel()
	if err := r.peer.Replicate(ctx, newest); err != nil {
		c.m.ReplicationFailures.Inc(r.peer.ID(), "read_repair")
		return
	}
	c.m.ReadRepairs.Inc("peer")
	c.log.Debug("read repair", "peer", r.peer.ID(), "key", newest.Key, "version", newest.Version.String())
}

// ApplyReplica stores a record sent by another coordinator.
func (c *Coordinator) ApplyReplica(rec store.Record) error {
	c.clock.Observe(rec.Version.TS)
	_, err := c.store.Apply(rec)
	return err
}

// SyncWith pulls every key that p has a newer copy of. It is pull-only:
// p pulls from us on its own schedule, so both sides converge.
func (c *Coordinator) SyncWith(ctx context.Context, p Peer) (int, error) {
	theirs, err := p.Digest(ctx)
	if err != nil {
		return 0, err
	}
	mine := c.store.Digest()
	repaired := 0
	for key, v := range theirs {
		if cur, ok := mine[key]; ok && !v.Newer(cur) {
			continue
		}
		rec, found, err := p.Fetch(ctx, key)
		if err != nil {
			return repaired, err
		}
		if !found {
			continue
		}
		c.clock.Observe(rec.Version.TS)
		applied, err := c.store.Apply(rec)
		if err != nil {
			return repaired, err
		}
		if applied {
			repaired++
		}
	}
	return repaired, nil
}

// AntiEntropy runs one SyncWith against every peer. Unreachable peers are
// skipped; they are retried on the next pass.
func (c *Coordinator) AntiEntropy(ctx context.Context) {
	for _, p := range c.peers {
		pctx, cancel := context.WithTimeout(ctx, 10*c.cfg.Timeout)
		n, err := c.SyncWith(pctx, p)
		cancel()
		if err != nil {
			c.m.AntiEntropyRuns.Inc("error")
			c.log.Debug("anti-entropy failed", "peer", p.ID(), "err", err)
			continue
		}
		c.m.AntiEntropyRuns.Inc("ok")
		if n > 0 {
			c.m.AntiEntropyRepairs.Add(float64(n))
			c.log.Info("anti-entropy repaired keys", "peer", p.ID(), "keys", n)
		}
	}
}

// ProbePeers pings every peer and records which ones answered.
func (c *Coordinator) ProbePeers(ctx context.Context) int {
	var up atomic.Int64
	var wg sync.WaitGroup
	for _, p := range c.peers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pctx, cancel := context.WithTimeout(ctx, c.cfg.Timeout)
			defer cancel()
			if err := p.Ping(pctx); err != nil {
				c.m.PeerUp.Set(0, p.ID())
				return
			}
			c.m.PeerUp.Set(1, p.ID())
			up.Add(1)
		}()
	}
	wg.Wait()
	c.reachable.Store(up.Load())
	return int(up.Load())
}

// Ready reports whether, as of the last probe, enough replicas are up to
// serve both reads and writes, and how many are up (this node included).
func (c *Coordinator) Ready() (bool, int, int) {
	up := int(c.reachable.Load()) + 1
	need := max(c.cfg.W, c.cfg.R)
	return up >= need, up, need
}
