// Command kvnode runs one node of the replicated key-value store.
//
// Every flag can also be set with an environment variable, shown in
// brackets in -help. Flags win over the environment.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/server"
)

type options struct {
	nodeID, listen, peerListen, adminListen, dataDir, peers, logLevel string
	sync                                                              bool
	w, r                                                              int
	peerTimeout, probeInterval, antiEntropy, shutdownTimeout          time.Duration
	probe                                                             string
}

func main() {
	opts, err := parseFlags(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if opts.probe != "" {
		os.Exit(probe(opts.probe))
	}
	if err := run(opts); err != nil {
		slog.Error("kvnode stopped", "err", err)
		os.Exit(1)
	}
}

func parseFlags(args []string) (options, error) {
	var o options
	fs := flag.NewFlagSet("kvnode", flag.ContinueOnError)
	fs.StringVar(&o.nodeID, "node-id", env("KV_NODE_ID", ""), "unique node ID [KV_NODE_ID]")
	fs.StringVar(&o.listen, "listen", env("KV_LISTEN", ":8080"), "client API, /healthz, /readyz, /metrics [KV_LISTEN]")
	fs.StringVar(&o.peerListen, "peer-listen", env("KV_PEER_LISTEN", ":7070"), "internal replication API [KV_PEER_LISTEN]")
	fs.StringVar(&o.adminListen, "admin-listen", env("KV_ADMIN_LISTEN", "127.0.0.1:6060"), "pprof; empty disables [KV_ADMIN_LISTEN]")
	fs.StringVar(&o.dataDir, "data-dir", env("KV_DATA_DIR", "./data"), "WAL directory; empty keeps data in memory only [KV_DATA_DIR]")
	fs.BoolVar(&o.sync, "sync", envBool("KV_SYNC", true), "fsync the WAL before acknowledging a write [KV_SYNC]")
	fs.StringVar(&o.peers, "peers", env("KV_PEERS", ""), "peers as id=url,id=url, e.g. kv2=http://kv2:7070 [KV_PEERS]")
	fs.IntVar(&o.w, "w", envInt("KV_W", 2), "write quorum, this node included [KV_W]")
	fs.IntVar(&o.r, "r", envInt("KV_R", 2), "read quorum, this node included [KV_R]")
	fs.DurationVar(&o.peerTimeout, "peer-timeout", envDuration("KV_PEER_TIMEOUT", 500*time.Millisecond), "timeout for each call to a peer [KV_PEER_TIMEOUT]")
	fs.DurationVar(&o.probeInterval, "probe-interval", envDuration("KV_PROBE_INTERVAL", 2*time.Second), "how often to ping peers for readiness [KV_PROBE_INTERVAL]")
	fs.DurationVar(&o.antiEntropy, "anti-entropy-interval", envDuration("KV_ANTI_ENTROPY_INTERVAL", 10*time.Second), "how often to sync with peers; 0 disables [KV_ANTI_ENTROPY_INTERVAL]")
	fs.DurationVar(&o.shutdownTimeout, "shutdown-timeout", envDuration("KV_SHUTDOWN_TIMEOUT", 10*time.Second), "time allowed for in-flight requests on SIGTERM [KV_SHUTDOWN_TIMEOUT]")
	fs.StringVar(&o.logLevel, "log-level", env("KV_LOG_LEVEL", "info"), "debug, info, warn or error [KV_LOG_LEVEL]")
	fs.StringVar(&o.probe, "probe", "", "GET this URL, exit 0 on 2xx; for container health checks")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	if o.probe == "" && o.nodeID == "" {
		return o, errors.New("-node-id (or KV_NODE_ID) is required")
	}
	return o, nil
}

func parsePeers(s string) (map[string]string, error) {
	peers := map[string]string{}
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		id, url, ok := strings.Cut(part, "=")
		if !ok || id == "" || !strings.HasPrefix(url, "http") {
			return nil, fmt.Errorf("bad peer %q, want id=http://host:port", part)
		}
		if _, dup := peers[id]; dup {
			return nil, fmt.Errorf("peer %q listed twice", id)
		}
		peers[id] = strings.TrimRight(url, "/")
	}
	return peers, nil
}

func run(o options) error {
	var level slog.Level
	if err := level.UnmarshalText([]byte(o.logLevel)); err != nil {
		return fmt.Errorf("bad log level: %w", err)
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(log)

	peers, err := parsePeers(o.peers)
	if err != nil {
		return err
	}
	if _, self := peers[o.nodeID]; self {
		return fmt.Errorf("node %q lists itself as a peer", o.nodeID)
	}
	srv, err := server.New(server.Config{
		NodeID: o.nodeID, DataDir: o.dataDir, SyncWrites: o.sync, Peers: peers,
		W: o.w, R: o.r, PeerTimeout: o.peerTimeout, ProbeInterval: o.probeInterval,
		AntiEntropyInterval: o.antiEntropy, Logger: log,
	})
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	servers := []*http.Server{
		newHTTPServer(o.listen, srv.ClientHandler()),
		newHTTPServer(o.peerListen, srv.PeerHandler()),
	}
	if o.adminListen != "" {
		admin := newHTTPServer(o.adminListen, server.AdminHandler())
		admin.WriteTimeout = 0 // CPU profiles stream for as long as asked
		servers = append(servers, admin)
	}

	errc := make(chan error, len(servers))
	for _, hs := range servers {
		ln, err := net.Listen("tcp", hs.Addr)
		if err != nil {
			return fmt.Errorf("listen %s: %w", hs.Addr, err)
		}
		go func() {
			if err := hs.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
				errc <- err
			}
		}()
	}
	bgCtx, cancelBg := context.WithCancel(context.Background())
	var bg sync.WaitGroup
	bg.Add(1)
	go func() {
		defer bg.Done()
		srv.Run(bgCtx)
	}()
	log.Info("kvnode started", "listen", o.listen, "peer_listen", o.peerListen, "admin_listen", o.adminListen,
		"peers", len(peers), "w", o.w, "r", o.r, "sync", o.sync, "data_dir", o.dataDir)

	var runErr error
	select {
	case <-ctx.Done():
		log.Info("shutdown signal received, draining")
	case runErr = <-errc:
		log.Error("server error, shutting down", "err", runErr)
	}

	// Stop taking new requests and let in-flight ones finish, then stop
	// the background loops and close the WAL cleanly.
	sctx, cancel := context.WithTimeout(context.Background(), o.shutdownTimeout)
	defer cancel()
	for _, hs := range servers {
		if err := hs.Shutdown(sctx); err != nil {
			log.Warn("http shutdown", "addr", hs.Addr, "err", err)
		}
	}
	cancelBg()
	bg.Wait()
	if err := srv.Close(); err != nil {
		return fmt.Errorf("close store: %w", err)
	}
	log.Info("kvnode stopped cleanly")
	return runErr
}

func newHTTPServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
}

func probe(url string) int {
	c := &http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get(url)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		fmt.Fprintln(os.Stderr, "status", resp.StatusCode)
		return 1
	}
	return 0
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	if v, err := strconv.ParseBool(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(key)); err == nil {
		return v
	}
	return def
}
