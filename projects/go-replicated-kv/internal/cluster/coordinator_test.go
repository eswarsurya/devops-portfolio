package cluster

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/metrics"
	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/store"
)

// fakePeer is an in-memory replica that can be made to fail or stall.
type fakePeer struct {
	id    string
	st    *store.Store
	mu    sync.Mutex
	down  bool
	delay time.Duration
}

var errDown = errors.New("connection refused")

func newFakePeer(id string) *fakePeer {
	st, _ := store.Open(store.Options{})
	return &fakePeer{id: id, st: st}
}

func (f *fakePeer) ID() string { return f.id }

func (f *fakePeer) set(down bool, delay time.Duration) {
	f.mu.Lock()
	f.down, f.delay = down, delay
	f.mu.Unlock()
}

func (f *fakePeer) wait(ctx context.Context) error {
	f.mu.Lock()
	down, delay := f.down, f.delay
	f.mu.Unlock()
	if down {
		return errDown
	}
	select {
	case <-time.After(delay):
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (f *fakePeer) Replicate(ctx context.Context, rec store.Record) error {
	if err := f.wait(ctx); err != nil {
		return err
	}
	_, err := f.st.Apply(rec)
	return err
}

func (f *fakePeer) Fetch(ctx context.Context, key string) (store.Record, bool, error) {
	if err := f.wait(ctx); err != nil {
		return store.Record{}, false, err
	}
	rec, ok := f.st.Get(key)
	return rec, ok, nil
}

func (f *fakePeer) Digest(ctx context.Context) (map[string]store.Version, error) {
	if err := f.wait(ctx); err != nil {
		return nil, err
	}
	return f.st.Digest(), nil
}

func (f *fakePeer) Ping(ctx context.Context) error { return f.wait(ctx) }

func newTestCoordinator(t testing.TB, id string, w, r int, peers ...*fakePeer) (*Coordinator, *metrics.Registry) {
	t.Helper()
	st, _ := store.Open(store.Options{})
	ps := make([]Peer, len(peers))
	for i, p := range peers {
		ps[i] = p
	}
	reg := metrics.NewRegistry()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	c, err := NewCoordinator(Config{NodeID: id, W: w, R: r, Timeout: 100 * time.Millisecond}, st, store.NewClock(nil), ps, NewMetrics(reg), log)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Wait)
	return c, reg
}

type peerState struct {
	down  bool
	delay time.Duration
}

var (
	up      = peerState{}
	down    = peerState{down: true}
	stalled = peerState{delay: 5 * time.Second} // far beyond the 100 ms timeout
)

func TestWriteQuorum(t *testing.T) {
	tests := []struct {
		name   string
		peers  [2]peerState
		wantOK bool
	}{
		{"all replicas up", [2]peerState{up, up}, true},
		{"one peer down", [2]peerState{up, down}, true},
		{"one peer stalled", [2]peerState{stalled, up}, true},
		{"both peers down", [2]peerState{down, down}, false},
		{"one down, one stalled", [2]peerState{down, stalled}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p2, p3 := newFakePeer("n2"), newFakePeer("n3")
			p2.set(tt.peers[0].down, tt.peers[0].delay)
			p3.set(tt.peers[1].down, tt.peers[1].delay)
			c, _ := newTestCoordinator(t, "n1", 2, 2, p2, p3)

			start := time.Now()
			_, err := c.Put(context.Background(), "k", []byte("v"))
			took := time.Since(start)

			if tt.wantOK && err != nil {
				t.Fatalf("Put failed: %v", err)
			}
			if !tt.wantOK && !errors.Is(err, ErrNoQuorum) {
				t.Fatalf("Put error = %v, want ErrNoQuorum", err)
			}
			// A stalled replica must cost at most the peer timeout, never
			// the full stall.
			if took > time.Second {
				t.Fatalf("Put took %v; the peer timeout is not being applied", took)
			}
		})
	}
}

func TestWriteReachesAllLiveReplicas(t *testing.T) {
	p2, p3 := newFakePeer("n2"), newFakePeer("n3")
	c, _ := newTestCoordinator(t, "n1", 2, 2, p2, p3)
	if _, err := c.Put(context.Background(), "k", []byte("v")); err != nil {
		t.Fatal(err)
	}
	c.Wait() // W=2 returns after one peer; the other finishes in the background
	for _, p := range []*fakePeer{p2, p3} {
		if rec, ok := p.st.Get("k"); !ok || string(rec.Value) != "v" {
			t.Fatalf("%s did not get the write", p.id)
		}
	}
}

func TestReadQuorumAndRepair(t *testing.T) {
	p2, p3 := newFakePeer("n2"), newFakePeer("n3")
	c, _ := newTestCoordinator(t, "n1", 2, 2, p2, p3)

	oldRec := store.Record{Key: "k", Value: []byte("old"), Version: store.Version{TS: 10, Node: "n1"}}
	newRec := store.Record{Key: "k", Value: []byte("new"), Version: store.Version{TS: 20, Node: "n2"}}
	// The local replica missed the latest write; n2 has it, n3 has nothing.
	if _, err := c.store.Apply(oldRec); err != nil {
		t.Fatal(err)
	}
	if _, err := p2.st.Apply(newRec); err != nil {
		t.Fatal(err)
	}
	p3.set(false, 50*time.Millisecond) // n3 answers after n2

	rec, found, err := c.Get(context.Background(), "k")
	if err != nil || !found {
		t.Fatalf("Get = %v, %v", found, err)
	}
	if string(rec.Value) != "new" {
		t.Fatalf("Get returned %q, want the newest value", rec.Value)
	}
	c.Wait()
	if got, _ := c.store.Get("k"); string(got.Value) != "new" {
		t.Fatalf("local replica not repaired: %q", got.Value)
	}
	if got, ok := p3.st.Get("k"); !ok || string(got.Value) != "new" {
		t.Fatalf("late replica n3 not repaired: %+v %v", got, ok)
	}
	if v := c.m.ReadRepairs.Value("local"); v != 1 {
		t.Fatalf("local read repairs = %v, want 1", v)
	}
	if v := c.m.ReadRepairs.Value("peer"); v != 1 {
		t.Fatalf("peer read repairs = %v, want 1", v)
	}
}

func TestReadFailsWithoutQuorum(t *testing.T) {
	p2, p3 := newFakePeer("n2"), newFakePeer("n3")
	p2.set(true, 0)
	p3.set(false, 5*time.Second)
	c, _ := newTestCoordinator(t, "n1", 2, 2, p2, p3)
	_, _, err := c.Get(context.Background(), "k")
	if !errors.Is(err, ErrNoQuorum) {
		t.Fatalf("Get error = %v, want ErrNoQuorum", err)
	}
	if v := c.m.QuorumFailures.Value("get"); v != 1 {
		t.Fatalf("quorum failure counter = %v, want 1", v)
	}
}

func TestDeleteWinsOverOlderValue(t *testing.T) {
	p2, p3 := newFakePeer("n2"), newFakePeer("n3")
	c, _ := newTestCoordinator(t, "n1", 2, 2, p2, p3)
	ctx := context.Background()
	if _, err := c.Put(ctx, "k", []byte("v")); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Delete(ctx, "k"); err != nil {
		t.Fatal(err)
	}
	if _, found, err := c.Get(ctx, "k"); err != nil || found {
		t.Fatalf("after delete: found=%v err=%v", found, err)
	}
}

func TestConcurrentWritersConvergeOnSameValue(t *testing.T) {
	// Two coordinators write the same key at the same time. Last writer
	// wins means one of the writes is lost, but every replica must end up
	// with the same one.
	shared1 := newFakePeer("n3")
	c1, _ := newTestCoordinator(t, "n1", 1, 1, shared1)
	c2, _ := newTestCoordinator(t, "n2", 1, 1, shared1)
	ctx := context.Background()
	v1, err := c1.Put(ctx, "k", []byte("from-n1"))
	if err != nil {
		t.Fatal(err)
	}
	v2, err := c2.Put(ctx, "k", []byte("from-n2"))
	if err != nil {
		t.Fatal(err)
	}
	c1.Wait()
	c2.Wait()
	// Anti-entropy both ways through the shared replica.
	if _, err := c1.SyncWith(ctx, shared1); err != nil {
		t.Fatal(err)
	}
	if _, err := c2.SyncWith(ctx, shared1); err != nil {
		t.Fatal(err)
	}
	want := "from-n1"
	if v2.Newer(v1) {
		want = "from-n2"
	}
	for name, st := range map[string]*store.Store{"n1": c1.store, "n2": c2.store, "n3": shared1.st} {
		if rec, _ := st.Get("k"); string(rec.Value) != want {
			t.Fatalf("%s has %q, want %q", name, rec.Value, want)
		}
	}
}

func TestAntiEntropyCatchesUpMissedWrites(t *testing.T) {
	p2 := newFakePeer("n2")
	c, _ := newTestCoordinator(t, "n1", 1, 1, p2)
	for i, k := range []string{"a", "b", "c"} {
		if _, err := p2.st.Apply(store.Record{Key: k, Value: []byte("v"), Version: store.Version{TS: uint64(i + 1), Node: "n2"}}); err != nil {
			t.Fatal(err)
		}
	}
	// One key we already have at the same version: must not be counted.
	if _, err := c.store.Apply(store.Record{Key: "a", Value: []byte("v"), Version: store.Version{TS: 1, Node: "n2"}}); err != nil {
		t.Fatal(err)
	}
	c.AntiEntropy(context.Background())
	if c.store.Len() != 3 {
		t.Fatalf("local store has %d keys, want 3", c.store.Len())
	}
	if v := c.m.AntiEntropyRepairs.Value(); v != 2 {
		t.Fatalf("repaired keys = %v, want 2", v)
	}
	p2.set(true, 0)
	c.AntiEntropy(context.Background())
	if v := c.m.AntiEntropyRuns.Value("error"); v != 1 {
		t.Fatalf("failed runs = %v, want 1", v)
	}
}

func TestReadiness(t *testing.T) {
	p2, p3 := newFakePeer("n2"), newFakePeer("n3")
	c, _ := newTestCoordinator(t, "n1", 2, 2, p2, p3)
	ctx := context.Background()
	steps := []struct {
		p2, p3    bool // down?
		wantReady bool
	}{
		{false, false, true},
		{true, false, true},
		{true, true, false},
		{false, true, true},
	}
	for i, s := range steps {
		p2.set(s.p2, 0)
		p3.set(s.p3, 0)
		c.ProbePeers(ctx)
		if ready, up, need := c.Ready(); ready != s.wantReady {
			t.Fatalf("step %d: ready=%v (up %d, need %d), want %v", i, ready, up, need, s.wantReady)
		}
	}
}

func TestConfigValidation(t *testing.T) {
	st, _ := store.Open(store.Options{})
	m := NewMetrics(metrics.NewRegistry())
	for _, wr := range [][2]int{{0, 1}, {1, 0}, {4, 1}, {1, 4}} {
		_, err := NewCoordinator(Config{NodeID: "n1", W: wr[0], R: wr[1]}, st, store.NewClock(nil), []Peer{newFakePeer("n2"), newFakePeer("n3")}, m, nil)
		if err == nil {
			t.Fatalf("W=%d R=%d accepted for N=3", wr[0], wr[1])
		}
	}
}

func BenchmarkPutQuorumFakePeers(b *testing.B) {
	c, _ := newTestCoordinator(b, "n1", 2, 2, newFakePeer("n2"), newFakePeer("n3"))
	val := make([]byte, 128)
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if _, err := c.Put(ctx, "k", val); err != nil {
			b.Fatal(err)
		}
	}
}
