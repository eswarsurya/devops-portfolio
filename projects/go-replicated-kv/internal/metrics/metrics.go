// Package metrics is a small Prometheus client: counters, gauges and
// histograms with labels, written in the Prometheus text exposition format
// (version 0.0.4). It exists so the service needs nothing outside the Go
// standard library.
package metrics

import (
	"bufio"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// DefaultBuckets are latency buckets in seconds. 0.1 must stay in the list:
// the latency SLO counts requests faster than 100 ms.
var DefaultBuckets = []float64{0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}

// Registry holds metrics and renders them.
type Registry struct {
	mu   sync.Mutex
	list []metric
}

type metric interface {
	write(w *bufio.Writer)
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry { return &Registry{} }

func (r *Registry) add(m metric) {
	r.mu.Lock()
	r.list = append(r.list, m)
	r.mu.Unlock()
}

// WriteText writes every metric in the text exposition format.
func (r *Registry) WriteText(w io.Writer) error {
	r.mu.Lock()
	list := append([]metric(nil), r.list...)
	r.mu.Unlock()
	bw := bufio.NewWriter(w)
	for _, m := range list {
		m.write(bw)
	}
	return bw.Flush()
}

// Handler serves the registry at /metrics.
func (r *Registry) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_ = r.WriteText(w)
	})
}

// vec is the shared part of every labelled metric: one series per
// distinct set of label values.
type vec[T any] struct {
	name, help, kind string
	labels           []string
	mu               sync.Mutex
	series           map[string]*entry[T]
	newT             func() *T
}

type entry[T any] struct {
	values []string
	v      *T
}

func newVec[T any](name, help, kind string, labels []string, newT func() *T) *vec[T] {
	return &vec[T]{name: name, help: help, kind: kind, labels: labels, series: map[string]*entry[T]{}, newT: newT}
}

// get returns the series for the label values; callers hold v.mu.
func (v *vec[T]) get(values []string) *T {
	if len(values) != len(v.labels) {
		panic(fmt.Sprintf("metric %s: got %d label values, want %d", v.name, len(values), len(v.labels)))
	}
	key := strings.Join(values, "\xff")
	e, ok := v.series[key]
	if !ok {
		e = &entry[T]{values: append([]string(nil), values...), v: v.newT()}
		v.series[key] = e
	}
	return e.v
}

// sorted returns the series in a stable order; callers hold v.mu.
func (v *vec[T]) sorted() []*entry[T] {
	keys := make([]string, 0, len(v.series))
	for k := range v.series {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]*entry[T], len(keys))
	for i, k := range keys {
		out[i] = v.series[k]
	}
	return out
}

func (v *vec[T]) header(w *bufio.Writer) {
	fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s %s\n", v.name, escapeHelp(v.help), v.name, v.kind)
}

// CounterVec is a counter with labels. Counters only go up.
type CounterVec struct{ v *vec[float64] }

// NewCounterVec registers a counter. A counter without labels starts at 0
// in the output, so rate() works before the first increment.
func (r *Registry) NewCounterVec(name, help string, labels ...string) *CounterVec {
	c := &CounterVec{v: newVec(name, help, "counter", labels, func() *float64 { return new(float64) })}
	if len(labels) == 0 {
		c.Add(0)
	}
	r.add(c)
	return c
}

// Inc adds 1.
func (c *CounterVec) Inc(values ...string) { c.Add(1, values...) }

// Add adds d, which must not be negative. Add(0, ...) creates the series.
func (c *CounterVec) Add(d float64, values ...string) {
	if d < 0 {
		panic("counter cannot decrease")
	}
	c.v.mu.Lock()
	*c.v.get(values) += d
	c.v.mu.Unlock()
}

// Value returns the current value (for tests).
func (c *CounterVec) Value(values ...string) float64 {
	c.v.mu.Lock()
	defer c.v.mu.Unlock()
	return *c.v.get(values)
}

func (c *CounterVec) write(w *bufio.Writer) {
	c.v.mu.Lock()
	defer c.v.mu.Unlock()
	c.v.header(w)
	for _, e := range c.v.sorted() {
		fmt.Fprintf(w, "%s%s %s\n", c.v.name, labelString(c.v.labels, e.values, ""), formatFloat(*e.v))
	}
}

// GaugeVec is a value that can go up and down.
type GaugeVec struct{ v *vec[float64] }

// NewGaugeVec registers a gauge.
func (r *Registry) NewGaugeVec(name, help string, labels ...string) *GaugeVec {
	g := &GaugeVec{v: newVec(name, help, "gauge", labels, func() *float64 { return new(float64) })}
	r.add(g)
	return g
}

// Set sets the gauge.
func (g *GaugeVec) Set(x float64, values ...string) {
	g.v.mu.Lock()
	*g.v.get(values) = x
	g.v.mu.Unlock()
}

// Value returns the current value (for tests).
func (g *GaugeVec) Value(values ...string) float64 {
	g.v.mu.Lock()
	defer g.v.mu.Unlock()
	return *g.v.get(values)
}

func (g *GaugeVec) write(w *bufio.Writer) {
	g.v.mu.Lock()
	defer g.v.mu.Unlock()
	g.v.header(w)
	for _, e := range g.v.sorted() {
		fmt.Fprintf(w, "%s%s %s\n", g.v.name, labelString(g.v.labels, e.values, ""), formatFloat(*e.v))
	}
}

// GaugeFunc is a gauge whose value is read when metrics are scraped.
type GaugeFunc struct {
	name, help string
	fn         func() float64
}

// NewGaugeFunc registers a gauge backed by fn.
func (r *Registry) NewGaugeFunc(name, help string, fn func() float64) {
	r.add(&GaugeFunc{name: name, help: help, fn: fn})
}

func (g *GaugeFunc) write(w *bufio.Writer) {
	fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n%s %s\n", g.name, escapeHelp(g.help), g.name, g.name, formatFloat(g.fn()))
}

// HistogramVec counts observations into cumulative buckets.
type HistogramVec struct {
	v       *vec[hist]
	buckets []float64
}

type hist struct {
	counts []uint64 // per bucket, not cumulative
	count  uint64
	sum    float64
}

// NewHistogramVec registers a histogram. buckets must be sorted ascending.
func (r *Registry) NewHistogramVec(name, help string, buckets []float64, labels ...string) *HistogramVec {
	b := append([]float64(nil), buckets...)
	h := &HistogramVec{buckets: b}
	h.v = newVec(name, help, "histogram", labels, func() *hist { return &hist{counts: make([]uint64, len(b))} })
	r.add(h)
	return h
}

// Observe records one value.
func (h *HistogramVec) Observe(x float64, values ...string) {
	i := sort.SearchFloat64s(h.buckets, x) // first bucket with upper bound >= x
	h.v.mu.Lock()
	s := h.v.get(values)
	if i < len(s.counts) {
		s.counts[i]++
	}
	s.count++
	s.sum += x
	h.v.mu.Unlock()
}

// Count returns the number of observations (for tests).
func (h *HistogramVec) Count(values ...string) uint64 {
	h.v.mu.Lock()
	defer h.v.mu.Unlock()
	return h.v.get(values).count
}

func (h *HistogramVec) write(w *bufio.Writer) {
	h.v.mu.Lock()
	defer h.v.mu.Unlock()
	h.v.header(w)
	for _, e := range h.v.sorted() {
		var cum uint64
		for i, ub := range h.buckets {
			cum += e.v.counts[i]
			fmt.Fprintf(w, "%s_bucket%s %d\n", h.v.name, labelString(h.v.labels, e.values, formatFloat(ub)), cum)
		}
		fmt.Fprintf(w, "%s_bucket%s %d\n", h.v.name, labelString(h.v.labels, e.values, "+Inf"), e.v.count)
		fmt.Fprintf(w, "%s_sum%s %s\n", h.v.name, labelString(h.v.labels, e.values, ""), formatFloat(e.v.sum))
		fmt.Fprintf(w, "%s_count%s %d\n", h.v.name, labelString(h.v.labels, e.values, ""), e.v.count)
	}
}

// labelString renders {a="x",b="y"}, adding le when it is not empty.
func labelString(names, values []string, le string) string {
	if len(names) == 0 && le == "" {
		return ""
	}
	var b strings.Builder
	b.WriteByte('{')
	for i, n := range names {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(n)
		b.WriteString(`="`)
		b.WriteString(escapeLabel(values[i]))
		b.WriteByte('"')
	}
	if le != "" {
		if len(names) > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`le="`)
		b.WriteString(le)
		b.WriteByte('"')
	}
	b.WriteByte('}')
	return b.String()
}

var (
	labelEscaper = strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)
	helpEscaper  = strings.NewReplacer(`\`, `\\`, "\n", `\n`)
)

func escapeLabel(s string) string { return labelEscaper.Replace(s) }
func escapeHelp(s string) string  { return helpEscaper.Replace(s) }

func formatFloat(f float64) string {
	switch {
	case math.IsInf(f, 1):
		return "+Inf"
	case math.IsInf(f, -1):
		return "-Inf"
	case math.IsNaN(f):
		return "NaN"
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}
