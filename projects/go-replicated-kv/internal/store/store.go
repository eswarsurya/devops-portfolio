package store

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// Options configures a Store.
type Options struct {
	// Dir holds the write-ahead log. Empty means memory only (tests and
	// benchmarks).
	Dir string
	// SyncEachWrite fsyncs the log before a write is acknowledged.
	SyncEachWrite bool
	Logger        *slog.Logger
}

// Store is one node's copy of the data.
type Store struct {
	mu   sync.RWMutex
	data map[string]Record
	wal  *WAL
}

// Open loads the store from its log, replaying every complete entry.
// If the log holds superseded entries it is compacted to one entry per key.
func Open(opts Options) (*Store, error) {
	s := &Store{data: make(map[string]Record)}
	if opts.Dir == "" {
		return s, nil
	}
	log := opts.Logger
	if log == nil {
		log = slog.Default()
	}
	if err := os.MkdirAll(opts.Dir, 0o700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	wal, recs, info, err := OpenWAL(filepath.Join(opts.Dir, "wal.log"), opts.SyncEachWrite)
	if err != nil {
		return nil, err
	}
	for _, rec := range recs {
		s.applyMemory(rec)
	}
	s.wal = wal
	if info.TruncatedBytes > 0 {
		log.Warn("wal had a torn tail, truncated it", "bytes", info.TruncatedBytes)
	}
	log.Info("wal replayed", "entries", info.Entries, "keys", len(s.data))
	if info.Entries > len(s.data) {
		if err := s.Compact(); err != nil {
			wal.Close()
			return nil, err
		}
		log.Info("wal compacted", "entries_before", info.Entries, "entries_after", len(s.data))
	}
	return s, nil
}

func (s *Store) applyMemory(rec Record) bool {
	cur, ok := s.data[rec.Key]
	if ok && !rec.Version.Newer(cur.Version) {
		return false
	}
	s.data[rec.Key] = rec
	return true
}

// Apply stores rec if it is newer than the copy already held (last writer
// wins). It returns true if rec was stored. The log is written before the
// map, so an acknowledged write survives a restart.
func (s *Store) Apply(rec Record) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cur, ok := s.data[rec.Key]; ok && !rec.Version.Newer(cur.Version) {
		return false, nil
	}
	if s.wal != nil {
		if err := s.wal.Append(rec); err != nil {
			return false, err
		}
	}
	s.data[rec.Key] = rec
	return true, nil
}

// Get returns the stored record for key, including tombstones.
func (s *Store) Get(key string) (Record, bool) {
	s.mu.RLock()
	rec, ok := s.data[key]
	s.mu.RUnlock()
	return rec, ok
}

// Digest returns the version of every key held, for anti-entropy.
func (s *Store) Digest() map[string]Version {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]Version, len(s.data))
	for k, rec := range s.data {
		out[k] = rec.Version
	}
	return out
}

// Len returns the number of records, tombstones included.
func (s *Store) Len() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.data)
}

// Compact rewrites the log with one entry per key.
func (s *Store) Compact() error {
	if s.wal == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	recs := make([]Record, 0, len(s.data))
	for _, rec := range s.data {
		recs = append(recs, rec)
	}
	sort.Slice(recs, func(i, j int) bool { return recs[i].Key < recs[j].Key })
	return s.wal.Rewrite(recs)
}

// Close flushes and closes the log.
func (s *Store) Close() error {
	if s.wal == nil {
		return nil
	}
	return s.wal.Close()
}
