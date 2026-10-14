// Package server wires a node together: storage, the coordinator, the
// client and peer HTTP APIs, metrics and the background loops.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/pprof"
	"regexp"
	"sort"
	"strconv"
	"time"

	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/cluster"
	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/metrics"
	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/store"
)

// MaxValueBytes caps the size of one value.
const MaxValueBytes = 1 << 20

var keyPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,200}$`)

// Config is everything a node needs to start.
type Config struct {
	NodeID     string
	DataDir    string // empty: memory only
	SyncWrites bool   // fsync the WAL before acknowledging
	Peers      map[string]string
	W, R       int
	// PeerTimeout bounds each call to a peer.
	PeerTimeout time.Duration
	// ProbeInterval is how often peers are pinged for /readyz.
	ProbeInterval time.Duration
	// AntiEntropyInterval is how often to sync with every peer. A pass
	// also runs at startup. Zero disables anti-entropy.
	AntiEntropyInterval time.Duration
	Logger              *slog.Logger
}

// Server is one running node.
type Server struct {
	cfg   Config
	log   *slog.Logger
	store *store.Store
	coord *cluster.Coordinator
	reg   *metrics.Registry

	requests *metrics.CounterVec
	latency  *metrics.HistogramVec
}

// New opens the store (replaying the WAL) and builds the node.
func New(cfg Config) (*Server, error) {
	log := cfg.Logger
	if log == nil {
		log = slog.Default()
	}
	log = log.With("node", cfg.NodeID)
	if cfg.NodeID == "" {
		return nil, errors.New("node id is required")
	}
	if cfg.ProbeInterval <= 0 {
		cfg.ProbeInterval = 2 * time.Second
	}
	st, err := store.Open(store.Options{Dir: cfg.DataDir, SyncEachWrite: cfg.SyncWrites, Logger: log})
	if err != nil {
		return nil, err
	}

	ids := make([]string, 0, len(cfg.Peers))
	for id := range cfg.Peers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	peers := make([]cluster.Peer, 0, len(ids))
	for _, id := range ids {
		peers = append(peers, cluster.NewHTTPPeer(id, cfg.Peers[id]))
	}

	reg := metrics.NewRegistry()
	s := &Server{
		cfg:      cfg,
		log:      log,
		store:    st,
		reg:      reg,
		requests: reg.NewCounterVec("kv_http_requests_total", "HTTP requests by route, method and status code.", "route", "method", "code"),
		latency:  reg.NewHistogramVec("kv_http_request_duration_seconds", "HTTP request latency by route and method.", metrics.DefaultBuckets, "route", "method"),
	}
	// Create the client-API series up front, at zero. Otherwise the first
	// 503 creates its series already at 1 and rate() never counts it.
	for _, method := range []string{"GET", "PUT", "DELETE"} {
		for _, code := range []string{"200", "500", "503"} {
			s.requests.Add(0, "kv", method, code)
		}
	}
	m := cluster.NewMetrics(reg)
	s.coord, err = cluster.NewCoordinator(cluster.Config{NodeID: cfg.NodeID, W: cfg.W, R: cfg.R, Timeout: cfg.PeerTimeout},
		st, store.NewClock(nil), peers, m, log)
	if err != nil {
		st.Close()
		return nil, err
	}
	reg.NewGaugeFunc("kv_records", "Records held by this node, tombstones included.", func() float64 { return float64(st.Len()) })
	reg.NewGaugeFunc("kv_ready", "1 if this node can reach a quorum.", func() float64 {
		if ok, _, _ := s.coord.Ready(); ok {
			return 1
		}
		return 0
	})
	if cfg.W+cfg.R <= s.coord.N() {
		log.Warn("W+R <= N: reads may miss acknowledged writes", "w", cfg.W, "r", cfg.R, "n", s.coord.N())
	}
	return s, nil
}

// Store gives tests access to this node's local data.
func (s *Server) Store() *store.Store { return s.store }

// Registry gives tests access to the metrics.
func (s *Server) Registry() *metrics.Registry { return s.reg }

// Run probes peers and runs anti-entropy until ctx is cancelled.
func (s *Server) Run(ctx context.Context) {
	s.coord.ProbePeers(ctx)
	probe := time.NewTicker(s.cfg.ProbeInterval)
	defer probe.Stop()

	var ae <-chan time.Time
	if s.cfg.AntiEntropyInterval > 0 {
		// Catch up on anything missed while this node was down.
		s.coord.AntiEntropy(ctx)
		t := time.NewTicker(s.cfg.AntiEntropyInterval)
		defer t.Stop()
		ae = t.C
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-probe.C:
			s.coord.ProbePeers(ctx)
		case <-ae:
			s.coord.AntiEntropy(ctx)
		}
	}
}

// Close waits for background replication and closes the store.
func (s *Server) Close() error {
	s.coord.Wait()
	return s.store.Close()
}

// ClientHandler serves the public API, health checks and metrics.
func (s *Server) ClientHandler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /kv/{key}", s.instrument("kv", s.handleGet))
	mux.Handle("PUT /kv/{key}", s.instrument("kv", s.handlePut))
	mux.Handle("DELETE /kv/{key}", s.instrument("kv", s.handleDelete))
	mux.Handle("GET /healthz", s.instrument("healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "node": s.cfg.NodeID})
	}))
	mux.Handle("GET /readyz", s.instrument("readyz", s.handleReady))
	mux.Handle("GET /metrics", s.reg.Handler())
	return mux
}

// PeerHandler serves the internal replication API. It belongs on its own
// port so it can be firewalled off from clients.
func (s *Server) PeerHandler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("PUT /internal/kv/{key}", s.instrument("internal_replicate", s.handleReplicate))
	mux.Handle("GET /internal/kv/{key}", s.instrument("internal_fetch", s.handleFetch))
	mux.Handle("GET /internal/digest", s.instrument("internal_digest", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, s.store.Digest())
	}))
	mux.Handle("GET /internal/ping", s.instrument("internal_ping", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	return mux
}

// AdminHandler serves pprof. Keep it on a port that is not exposed.
func AdminHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	return mux
}

func (s *Server) handlePut(w http.ResponseWriter, r *http.Request) {
	key, ok := validKey(w, r)
	if !ok {
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxValueBytes))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("value larger than %d bytes", MaxValueBytes))
		return
	}
	v, err := s.coord.Put(r.Context(), key, body)
	if err != nil {
		s.writeCoordError(w, r, "put", key, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"key": key, "version": v.String()})
}

func (s *Server) handleGet(w http.ResponseWriter, r *http.Request) {
	key, ok := validKey(w, r)
	if !ok {
		return
	}
	rec, found, err := s.coord.Get(r.Context(), key)
	if err != nil {
		s.writeCoordError(w, r, "get", key, err)
		return
	}
	if !found {
		writeError(w, http.StatusNotFound, "key not found")
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-KV-Version", rec.Version.String())
	w.Header().Set("Content-Length", strconv.Itoa(len(rec.Value)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(rec.Value)
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	key, ok := validKey(w, r)
	if !ok {
		return
	}
	v, err := s.coord.Delete(r.Context(), key)
	if err != nil {
		s.writeCoordError(w, r, "delete", key, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"key": key, "version": v.String(), "deleted": "true"})
}

func (s *Server) handleReady(w http.ResponseWriter, _ *http.Request) {
	ready, up, need := s.coord.Ready()
	code := http.StatusOK
	if !ready {
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, map[string]any{"ready": ready, "replicas_up": up, "replicas_needed": need})
}

func (s *Server) handleReplicate(w http.ResponseWriter, r *http.Request) {
	var rec store.Record
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2*MaxValueBytes)).Decode(&rec); err != nil {
		writeError(w, http.StatusBadRequest, "bad record: "+err.Error())
		return
	}
	if rec.Key != r.PathValue("key") || rec.Version.IsZero() {
		writeError(w, http.StatusBadRequest, "record key or version does not match")
		return
	}
	if err := s.coord.ApplyReplica(rec); err != nil {
		s.log.Error("apply replica", "key", rec.Key, "err", err)
		writeError(w, http.StatusInternalServerError, "storage error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleFetch(w http.ResponseWriter, r *http.Request) {
	rec, ok := s.store.Get(r.PathValue("key"))
	if !ok {
		writeError(w, http.StatusNotFound, "key not found")
		return
	}
	writeJSON(w, http.StatusOK, rec)
}

func (s *Server) writeCoordError(w http.ResponseWriter, r *http.Request, op, key string, err error) {
	switch {
	case errors.Is(err, cluster.ErrNoQuorum):
		s.log.Warn("quorum not reached", "op", op, "key", key, "err", err)
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusServiceUnavailable, err.Error())
	case r.Context().Err() != nil:
		// The client went away; nobody reads this response.
		writeError(w, 499, "client closed request")
	default:
		s.log.Error("request failed", "op", op, "key", key, "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}

func validKey(w http.ResponseWriter, r *http.Request) (string, bool) {
	key := r.PathValue("key")
	if !keyPattern.MatchString(key) {
		writeError(w, http.StatusBadRequest, "key must be 1-200 characters from A-Z a-z 0-9 . _ : -")
		return "", false
	}
	return key, true
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// statusRecorder captures the status code for metrics.
type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.code = code
	r.ResponseWriter.WriteHeader(code)
}

// instrument counts requests and observes latency under a fixed route
// label (never the raw path, which would make one series per key).
func (s *Server) instrument(route string, h http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		h(rec, r)
		s.requests.Inc(route, r.Method, strconv.Itoa(rec.code))
		s.latency.Observe(time.Since(start).Seconds(), route, r.Method)
	})
}
