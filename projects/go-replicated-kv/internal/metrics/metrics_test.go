package metrics

import (
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestTextExposition(t *testing.T) {
	r := NewRegistry()
	reqs := r.NewCounterVec("kv_http_requests_total", "Requests by route and code.", "route", "code")
	reqs.Inc("kv", "200")
	reqs.Inc("kv", "200")
	reqs.Inc("kv", "503")
	r.NewCounterVec("kv_read_repairs_total", "Stale replicas fixed on read.")
	lat := r.NewHistogramVec("kv_latency_seconds", "Latency.", []float64{0.01, 0.1}, "route")
	lat.Observe(0.005, "kv")
	lat.Observe(0.05, "kv")
	lat.Observe(0.1, "kv") // exactly on a bound counts in that bucket
	lat.Observe(3, "kv")
	up := r.NewGaugeVec("kv_peer_up", "Peer reachable.", "peer")
	up.Set(1, `n"2`)
	r.NewGaugeFunc("kv_records", "Records held.", func() float64 { return 42 })

	var b strings.Builder
	if err := r.WriteText(&b); err != nil {
		t.Fatal(err)
	}
	want := `# HELP kv_http_requests_total Requests by route and code.
# TYPE kv_http_requests_total counter
kv_http_requests_total{route="kv",code="200"} 2
kv_http_requests_total{route="kv",code="503"} 1
# HELP kv_read_repairs_total Stale replicas fixed on read.
# TYPE kv_read_repairs_total counter
kv_read_repairs_total 0
# HELP kv_latency_seconds Latency.
# TYPE kv_latency_seconds histogram
kv_latency_seconds_bucket{route="kv",le="0.01"} 1
kv_latency_seconds_bucket{route="kv",le="0.1"} 3
kv_latency_seconds_bucket{route="kv",le="+Inf"} 4
kv_latency_seconds_sum{route="kv"} 3.155
kv_latency_seconds_count{route="kv"} 4
# HELP kv_peer_up Peer reachable.
# TYPE kv_peer_up gauge
kv_peer_up{peer="n\"2"} 1
# HELP kv_records Records held.
# TYPE kv_records gauge
kv_records 42
`
	if got := b.String(); got != want {
		t.Fatalf("exposition mismatch\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

func TestHandlerContentType(t *testing.T) {
	r := NewRegistry()
	r.NewCounterVec("x_total", "x")
	rec := httptest.NewRecorder()
	r.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/metrics", nil))
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain; version=0.0.4") {
		t.Fatalf("content type %q", ct)
	}
}

func TestConcurrentUpdates(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounterVec("c_total", "c", "k")
	h := r.NewHistogramVec("h", "h", DefaultBuckets, "k")
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 1000 {
				c.Inc("a")
				h.Observe(0.02, "a")
			}
			_ = r.WriteText(&strings.Builder{})
		}()
	}
	wg.Wait()
	if c.Value("a") != 8000 || h.Count("a") != 8000 {
		t.Fatalf("lost updates: counter %v, histogram %d", c.Value("a"), h.Count("a"))
	}
}
