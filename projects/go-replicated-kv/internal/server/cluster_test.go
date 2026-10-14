package server

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/store"
)

// testNode is one node running on real loopback sockets, so peers talk to
// each other over HTTP exactly as they do in production.
type testNode struct {
	id                   string
	dir                  string
	clientAddr, peerAddr string
	peers                map[string]string
	antiEntropy          time.Duration

	srv          *Server
	client, peer *httptest.Server
	cancel       context.CancelFunc
	done         chan struct{}
	running      bool
}

func listen(t *testing.T, addr string) net.Listener {
	t.Helper()
	var ln net.Listener
	var err error
	// Rebinding the same port right after a stop can briefly fail.
	for range 50 {
		if ln, err = net.Listen("tcp", addr); err == nil {
			return ln
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("listen %s: %v", addr, err)
	return nil
}

// startCluster starts n nodes with W=2, R=2.
func startCluster(t *testing.T, n int, antiEntropy time.Duration) []*testNode {
	t.Helper()
	nodes := make([]*testNode, n)
	clientLns := make([]net.Listener, n)
	peerLns := make([]net.Listener, n)
	for i := range n {
		clientLns[i] = listen(t, "127.0.0.1:0")
		peerLns[i] = listen(t, "127.0.0.1:0")
		nodes[i] = &testNode{
			id:          fmt.Sprintf("n%d", i+1),
			dir:         t.TempDir(),
			clientAddr:  clientLns[i].Addr().String(),
			peerAddr:    peerLns[i].Addr().String(),
			antiEntropy: antiEntropy,
		}
	}
	for _, nd := range nodes {
		nd.peers = map[string]string{}
		for _, other := range nodes {
			if other != nd {
				nd.peers[other.id] = "http://" + other.peerAddr
			}
		}
	}
	for i, nd := range nodes {
		nd.start(t, clientLns[i], peerLns[i])
	}
	t.Cleanup(func() {
		for _, nd := range nodes {
			nd.stop(t)
		}
	})
	return nodes
}

func (nd *testNode) start(t *testing.T, clientLn, peerLn net.Listener) {
	t.Helper()
	srv, err := New(Config{
		NodeID: nd.id, DataDir: nd.dir, SyncWrites: true, Peers: nd.peers, W: 2, R: 2,
		PeerTimeout: 300 * time.Millisecond, ProbeInterval: 50 * time.Millisecond,
		AntiEntropyInterval: nd.antiEntropy,
		Logger:              slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	nd.srv = srv
	nd.client = &httptest.Server{Listener: clientLn, Config: &http.Server{Handler: srv.ClientHandler()}}
	nd.peer = &httptest.Server{Listener: peerLn, Config: &http.Server{Handler: srv.PeerHandler()}}
	nd.client.Start()
	nd.peer.Start()
	ctx, cancel := context.WithCancel(context.Background())
	nd.cancel = cancel
	nd.done = make(chan struct{})
	go func() {
		defer close(nd.done)
		srv.Run(ctx)
	}()
	nd.running = true
}

// stop simulates the node process dying: its sockets close and peers get
// connection refused. The WAL directory is kept for restart.
func (nd *testNode) stop(t *testing.T) {
	t.Helper()
	if !nd.running {
		return
	}
	nd.client.Close()
	nd.peer.Close()
	nd.cancel()
	<-nd.done
	if err := nd.srv.Close(); err != nil {
		t.Fatal(err)
	}
	nd.running = false
}

// restart brings the node back on the same addresses with the same data dir.
func (nd *testNode) restart(t *testing.T) {
	t.Helper()
	nd.start(t, listen(t, nd.clientAddr), listen(t, nd.peerAddr))
}

func (nd *testNode) url(path string) string { return "http://" + nd.clientAddr + path }

var httpClient = &http.Client{Timeout: 5 * time.Second}

func do(t *testing.T, method, url, body string) (int, string) {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for: %s", what)
}

func (nd *testNode) hasLocal(key, value string) bool {
	rec, ok := nd.srv.Store().Get(key)
	return ok && !rec.Deleted && string(rec.Value) == value
}

func waitReady(t *testing.T, nodes ...*testNode) {
	t.Helper()
	for _, nd := range nodes {
		eventually(t, nd.id+" ready", func() bool {
			code, _ := do(t, "GET", nd.url("/readyz"), "")
			return code == http.StatusOK
		})
	}
}

// TestFailureAndRecovery walks one cluster through losing a node, losing
// quorum, and coming back.
func TestFailureAndRecovery(t *testing.T) {
	nodes := startCluster(t, 3, 100*time.Millisecond)
	n1, n2, n3 := nodes[0], nodes[1], nodes[2]
	waitReady(t, nodes...)

	// 1. Healthy cluster: a write on one node is readable on every node.
	if code, body := do(t, "PUT", n1.url("/kv/user:1"), "alice"); code != http.StatusOK {
		t.Fatalf("PUT on healthy cluster: %d %s", code, body)
	}
	for _, nd := range nodes {
		if code, body := do(t, "GET", nd.url("/kv/user:1"), ""); code != http.StatusOK || body != "alice" {
			t.Fatalf("GET via %s: %d %q", nd.id, code, body)
		}
	}
	eventually(t, "write replicated to all 3 nodes", func() bool {
		return n1.hasLocal("user:1", "alice") && n2.hasLocal("user:1", "alice") && n3.hasLocal("user:1", "alice")
	})

	// 2. One node down: quorum (2 of 3) still holds, reads and writes work.
	n3.stop(t)
	// The stopped node's WAL already holds the acknowledged write.
	st, err := store.Open(store.Options{Dir: n3.dir, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))})
	if err != nil {
		t.Fatal(err)
	}
	if rec, ok := st.Get("user:1"); !ok || string(rec.Value) != "alice" {
		t.Fatalf("n3 WAL replay lost an acknowledged write: %+v %v", rec, ok)
	}
	st.Close()
	if code, body := do(t, "PUT", n1.url("/kv/user:2"), "bob"); code != http.StatusOK {
		t.Fatalf("PUT with one node down: %d %s", code, body)
	}
	if code, body := do(t, "GET", n2.url("/kv/user:2"), ""); code != http.StatusOK || body != "bob" {
		t.Fatalf("GET with one node down: %d %q", code, body)
	}
	if code, _ := do(t, "DELETE", n2.url("/kv/user:1"), ""); code != http.StatusOK {
		t.Fatalf("DELETE with one node down: %d", code)
	}

	// 3. Two nodes down: no quorum. The survivor refuses with 503 instead
	// of serving data it cannot confirm, and reports not ready.
	n2.stop(t)
	if code, _ := do(t, "PUT", n1.url("/kv/user:3"), "carol"); code != http.StatusServiceUnavailable {
		t.Fatalf("PUT without quorum = %d, want 503", code)
	}
	if code, _ := do(t, "GET", n1.url("/kv/user:2"), ""); code != http.StatusServiceUnavailable {
		t.Fatalf("GET without quorum = %d, want 503", code)
	}
	eventually(t, "n1 reports not ready", func() bool {
		code, _ := do(t, "GET", n1.url("/readyz"), "")
		return code == http.StatusServiceUnavailable
	})
	if code, _ := do(t, "GET", n1.url("/healthz"), ""); code != http.StatusOK {
		t.Fatalf("liveness must stay OK while quorum is lost, got %d", code)
	}

	// 4. Restart both. n3 replays its WAL, then catches up on what it
	// missed (a new key and a delete) through anti-entropy.
	n3.restart(t)
	n2.restart(t)
	waitReady(t, nodes...)
	eventually(t, "n3 catches up on writes made while it was down", func() bool {
		rec, ok := n3.srv.Store().Get("user:1")
		return n3.hasLocal("user:2", "bob") && ok && rec.Deleted
	})
	if code, _ := do(t, "PUT", n1.url("/kv/user:3"), "carol"); code != http.StatusOK {
		t.Fatalf("PUT after recovery: %d", code)
	}
	if code, _ := do(t, "GET", n3.url("/kv/user:1"), ""); code != http.StatusNotFound {
		t.Fatalf("deleted key readable after recovery: %d", code)
	}
	eventually(t, "n3 counts the keys repaired by anti-entropy", func() bool {
		_, metrics := do(t, "GET", n3.url("/metrics"), "")
		return strings.Contains(metrics, "\nkv_antientropy_repaired_keys_total ") &&
			!strings.Contains(metrics, "\nkv_antientropy_repaired_keys_total 0\n")
	})
}

// TestReadRepairFixesStaleReplica turns anti-entropy off so the only way
// a stale replica can be fixed is through read repair.
func TestReadRepairFixesStaleReplica(t *testing.T) {
	nodes := startCluster(t, 3, 0)
	n1, n3 := nodes[0], nodes[2]
	waitReady(t, nodes...)

	do(t, "PUT", n1.url("/kv/config"), "v1")
	eventually(t, "v1 on n3", func() bool { return n3.hasLocal("config", "v1") })
	n3.stop(t)
	if code, _ := do(t, "PUT", n1.url("/kv/config"), "v2"); code != http.StatusOK {
		t.Fatalf("PUT v2: %d", code)
	}
	// Let n1's background attempt to reach n3 finish (and fail) first, or
	// it can land on the restarted n3 and the replica is no longer stale.
	n1.srv.coord.Wait()
	n3.restart(t)
	waitReady(t, n3)
	if !n3.hasLocal("config", "v1") {
		t.Fatal("expected n3 to still hold the stale v1")
	}
	// The read through n3 sees v1 locally and v2 on a peer, returns v2,
	// and writes v2 back to n3.
	if code, body := do(t, "GET", n3.url("/kv/config"), ""); code != http.StatusOK || body != "v2" {
		t.Fatalf("GET via stale node = %d %q, want v2", code, body)
	}
	eventually(t, "n3 repaired to v2 and counted", func() bool {
		_, metrics := do(t, "GET", n3.url("/metrics"), "")
		return n3.hasLocal("config", "v2") && strings.Contains(metrics, `kv_read_repairs_total{target="local"} 1`)
	})
}

func TestClientAPIValidation(t *testing.T) {
	nodes := startCluster(t, 3, 0)
	n1 := nodes[0]
	waitReady(t, nodes...)
	tests := []struct {
		method, path, body string
		want               int
	}{
		{"GET", "/kv/no-such-key-zq", "", http.StatusNotFound},
		{"PUT", "/kv/bad%20key", "x", http.StatusBadRequest},
		{"PUT", "/kv/" + strings.Repeat("k", 201), "x", http.StatusBadRequest},
		{"PUT", "/kv/big", strings.Repeat("x", MaxValueBytes+1), http.StatusRequestEntityTooLarge},
		{"POST", "/kv/k", "x", http.StatusMethodNotAllowed},
		{"PUT", "/kv/empty", "", http.StatusOK},
	}
	for _, tt := range tests {
		if code, body := do(t, tt.method, n1.url(tt.path), tt.body); code != tt.want {
			t.Errorf("%s %s = %d (%s), want %d", tt.method, tt.path[:min(len(tt.path), 30)], code, body, tt.want)
		}
	}
	// Metrics use the route name, never the raw key.
	_, metrics := do(t, "GET", n1.url("/metrics"), "")
	if !strings.Contains(metrics, `kv_http_requests_total{route="kv",method="GET",code="404"} 1`) {
		t.Fatalf("missing request counter in:\n%s", metrics)
	}
	if strings.Contains(metrics, "no-such-key-zq") {
		t.Fatal("raw key leaked into a metric label")
	}
}

func BenchmarkClusterPut(b *testing.B) {
	nodes := benchCluster(b)
	val := strings.Repeat("v", 128)
	client := &http.Client{Transport: &http.Transport{MaxIdleConnsPerHost: 64}}
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		i := 0
		for pb.Next() {
			i++
			req, _ := http.NewRequest("PUT", nodes[i%3]+"/kv/bench-"+fmt.Sprint(i%1000), strings.NewReader(val))
			resp, err := client.Do(req)
			if err != nil {
				b.Error(err)
				return
			}
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				b.Errorf("status %d", resp.StatusCode)
				return
			}
		}
	})
}

// benchCluster starts 3 in-memory nodes (no fsync) and returns their client URLs.
func benchCluster(b *testing.B) []string {
	b.Helper()
	type pair struct{ client, peer net.Listener }
	lns := make([]pair, 3)
	for i := range lns {
		c, _ := net.Listen("tcp", "127.0.0.1:0")
		p, _ := net.Listen("tcp", "127.0.0.1:0")
		lns[i] = pair{c, p}
	}
	var urls []string
	var closers []func()
	for i := range lns {
		peers := map[string]string{}
		for j := range lns {
			if j != i {
				peers[fmt.Sprintf("n%d", j+1)] = "http://" + lns[j].peer.Addr().String()
			}
		}
		srv, err := New(Config{NodeID: fmt.Sprintf("n%d", i+1), Peers: peers, W: 2, R: 2,
			PeerTimeout: time.Second, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))})
		if err != nil {
			b.Fatal(err)
		}
		cs := &httptest.Server{Listener: lns[i].client, Config: &http.Server{Handler: srv.ClientHandler()}}
		ps := &httptest.Server{Listener: lns[i].peer, Config: &http.Server{Handler: srv.PeerHandler()}}
		cs.Start()
		ps.Start()
		urls = append(urls, cs.URL)
		closers = append(closers, func() { cs.Close(); ps.Close(); srv.Close() })
	}
	b.Cleanup(func() {
		for _, c := range closers {
			c()
		}
	})
	return urls
}
