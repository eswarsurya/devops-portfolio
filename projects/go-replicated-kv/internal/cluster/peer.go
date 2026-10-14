// Package cluster coordinates reads and writes across replicas: quorum
// writes, quorum reads with read repair, and anti-entropy.
package cluster

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"

	"github.com/eswarsurya/devops-portfolio/projects/go-replicated-kv/internal/store"
)

// Peer is another replica, as seen by a coordinator.
type Peer interface {
	ID() string
	// Replicate asks the peer to store rec (it keeps it only if newer).
	Replicate(ctx context.Context, rec store.Record) error
	// Fetch returns the peer's local copy of key, tombstones included.
	Fetch(ctx context.Context, key string) (store.Record, bool, error)
	// Digest returns the version of every key the peer holds.
	Digest(ctx context.Context) (map[string]store.Version, error)
	// Ping checks the peer is up.
	Ping(ctx context.Context) error
}

// HTTPPeer talks to a peer's internal replication API.
type HTTPPeer struct {
	id     string
	base   string
	client *http.Client
}

// NewHTTPPeer returns a peer at baseURL (for example http://kv2:7070).
func NewHTTPPeer(id, baseURL string) *HTTPPeer {
	tr := &http.Transport{
		DialContext:         (&net.Dialer{Timeout: time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns:        256,
		MaxIdleConnsPerHost: 256,
		IdleConnTimeout:     90 * time.Second,
	}
	// No client-wide timeout: every call carries a context deadline.
	return &HTTPPeer{id: id, base: baseURL, client: &http.Client{Transport: tr}}
}

// ID returns the peer's node ID.
func (p *HTTPPeer) ID() string { return p.id }

func (p *HTTPPeer) keyURL(key string) string { return p.base + "/internal/kv/" + url.PathEscape(key) }

// Replicate sends rec to the peer.
func (p *HTTPPeer) Replicate(ctx context.Context, rec store.Record) error {
	body, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, p.keyURL(rec.Key), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer drain(resp)
	if resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("replicate to %s: status %d", p.id, resp.StatusCode)
	}
	return nil
}

// Fetch reads the peer's local copy of key.
func (p *HTTPPeer) Fetch(ctx context.Context, key string) (store.Record, bool, error) {
	var rec store.Record
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.keyURL(key), nil)
	if err != nil {
		return rec, false, err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return rec, false, err
	}
	defer drain(resp)
	switch resp.StatusCode {
	case http.StatusOK:
		if err := json.NewDecoder(resp.Body).Decode(&rec); err != nil {
			return rec, false, fmt.Errorf("decode record from %s: %w", p.id, err)
		}
		return rec, true, nil
	case http.StatusNotFound:
		return rec, false, nil
	default:
		return rec, false, fmt.Errorf("fetch from %s: status %d", p.id, resp.StatusCode)
	}
}

// Digest returns the peer's key versions.
func (p *HTTPPeer) Digest(ctx context.Context) (map[string]store.Version, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.base+"/internal/digest", nil)
	if err != nil {
		return nil, err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer drain(resp)
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("digest from %s: status %d", p.id, resp.StatusCode)
	}
	var d map[string]store.Version
	if err := json.NewDecoder(resp.Body).Decode(&d); err != nil {
		return nil, fmt.Errorf("decode digest from %s: %w", p.id, err)
	}
	return d, nil
}

// Ping checks the peer's internal API answers.
func (p *HTTPPeer) Ping(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.base+"/internal/ping", nil)
	if err != nil {
		return err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer drain(resp)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("ping %s: status %d", p.id, resp.StatusCode)
	}
	return nil
}

// drain reads and closes the body so the connection can be reused.
func drain(resp *http.Response) {
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	resp.Body.Close()
}
