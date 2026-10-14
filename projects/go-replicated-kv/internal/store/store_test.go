package store

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func TestVersionCompare(t *testing.T) {
	tests := []struct {
		name string
		a, b Version
		want int
	}{
		{"equal", Version{10, "n1"}, Version{10, "n1"}, 0},
		{"older timestamp", Version{9, "n3"}, Version{10, "n1"}, -1},
		{"newer timestamp", Version{11, "n1"}, Version{10, "n3"}, 1},
		{"tie broken by node id", Version{10, "n2"}, Version{10, "n1"}, 1},
		{"tie broken by node id, other way", Version{10, "n1"}, Version{10, "n2"}, -1},
		{"anything beats zero", Version{1, ""}, Version{}, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.a.Compare(tt.b); got != tt.want {
				t.Fatalf("Compare(%v, %v) = %d, want %d", tt.a, tt.b, got, tt.want)
			}
			if got := tt.b.Compare(tt.a); got != -tt.want {
				t.Fatalf("Compare is not antisymmetric for %v, %v", tt.a, tt.b)
			}
		})
	}
}

func TestClockNeverGoesBackwards(t *testing.T) {
	wall := time.UnixMicro(1_000_000)
	c := NewClock(func() time.Time { return wall })
	a := c.Next()
	b := c.Next() // same wall time: must still increase
	if b <= a {
		t.Fatalf("second timestamp %d not after %d", b, a)
	}
	wall = wall.Add(-time.Hour) // wall clock jumps back (NTP step)
	if d := c.Next(); d <= b {
		t.Fatalf("timestamp went backwards after clock step: %d <= %d", d, b)
	}
	c.Observe(5_000_000) // a peer is ahead of us
	if e := c.Next(); e <= 5_000_000 {
		t.Fatalf("Next() = %d, want > observed 5000000", e)
	}
}

func TestApplyLastWriterWins(t *testing.T) {
	s, err := Open(Options{})
	if err != nil {
		t.Fatal(err)
	}
	steps := []struct {
		rec       Record
		wantApply bool
		wantValue string
	}{
		{Record{Key: "k", Value: []byte("a"), Version: Version{10, "n1"}}, true, "a"},
		{Record{Key: "k", Value: []byte("old"), Version: Version{9, "n3"}}, false, "a"},
		{Record{Key: "k", Value: []byte("dup"), Version: Version{10, "n1"}}, false, "a"},
		{Record{Key: "k", Value: []byte("b"), Version: Version{10, "n2"}}, true, "b"},
		{Record{Key: "k", Deleted: true, Version: Version{12, "n1"}}, true, ""},
		{Record{Key: "k", Value: []byte("late"), Version: Version{11, "n3"}}, false, ""},
	}
	for i, st := range steps {
		applied, err := s.Apply(st.rec)
		if err != nil {
			t.Fatal(err)
		}
		if applied != st.wantApply {
			t.Fatalf("step %d: applied = %v, want %v", i, applied, st.wantApply)
		}
		got, _ := s.Get("k")
		if string(got.Value) != st.wantValue {
			t.Fatalf("step %d: value = %q, want %q", i, got.Value, st.wantValue)
		}
	}
	if got, _ := s.Get("k"); !got.Deleted {
		t.Fatal("tombstone was overwritten by an older write")
	}
}

func TestWALReplayAfterRestart(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(Options{Dir: dir, SyncEachWrite: true, Logger: quietLogger()})
	if err != nil {
		t.Fatal(err)
	}
	mustApply(t, s, Record{Key: "a", Value: []byte("1"), Version: Version{1, "n1"}})
	mustApply(t, s, Record{Key: "b", Value: []byte("2"), Version: Version{2, "n1"}})
	mustApply(t, s, Record{Key: "a", Value: []byte("3"), Version: Version{3, "n2"}})
	mustApply(t, s, Record{Key: "b", Deleted: true, Version: Version{4, "n1"}})
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	s2, err := Open(Options{Dir: dir, Logger: quietLogger()})
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	if got, ok := s2.Get("a"); !ok || string(got.Value) != "3" || got.Version != (Version{3, "n2"}) {
		t.Fatalf("a after replay = %+v, %v", got, ok)
	}
	if got, ok := s2.Get("b"); !ok || !got.Deleted {
		t.Fatalf("b after replay = %+v, want tombstone", got)
	}
	// Replay saw 4 entries for 2 keys, so the log was compacted to 2.
	f, err := os.Open(filepath.Join(dir, "wal.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	recs, _, err := readFrames(f)
	if err != nil || len(recs) != 2 {
		t.Fatalf("compacted wal has %d entries (err %v), want 2", len(recs), err)
	}
}

func TestWALCompactionKeepsLatest(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(Options{Dir: dir, Logger: quietLogger()})
	if err != nil {
		t.Fatal(err)
	}
	for i := range 100 {
		mustApply(t, s, Record{Key: "hot", Value: []byte{byte(i)}, Version: Version{uint64(i + 1), "n1"}})
	}
	s.Close()
	before := fileSize(t, filepath.Join(dir, "wal.log"))

	s2, err := Open(Options{Dir: dir, Logger: quietLogger()})
	if err != nil {
		t.Fatal(err)
	}
	after := fileSize(t, filepath.Join(dir, "wal.log"))
	if after >= before/10 {
		t.Fatalf("compaction did not shrink the log: %d -> %d bytes", before, after)
	}
	// Writes after compaction must still be durable.
	mustApply(t, s2, Record{Key: "new", Value: []byte("x"), Version: Version{500, "n1"}})
	s2.Close()
	s3, err := Open(Options{Dir: dir, Logger: quietLogger()})
	if err != nil {
		t.Fatal(err)
	}
	defer s3.Close()
	if got, _ := s3.Get("hot"); got.Value[0] != 99 {
		t.Fatalf("hot = %v, want last value 99", got.Value)
	}
	if _, ok := s3.Get("new"); !ok {
		t.Fatal("write made after compaction was lost")
	}
}

func TestWALTornTailIsTruncated(t *testing.T) {
	tests := []struct {
		name    string
		corrupt func(t *testing.T, path string)
	}{
		{"half-written frame", func(t *testing.T, path string) {
			// Simulate a crash in the middle of an append: a header that
			// promises 200 bytes followed by only a few.
			appendBytes(t, path, []byte{0, 0, 0, 200, 1, 2, 3, 4, '{', '"'})
		}},
		{"flipped bit in last entry", func(t *testing.T, path string) {
			b, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			b[len(b)-3] ^= 0xff
			if err := os.WriteFile(path, b, 0o600); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "wal.log")
			w, _, _, err := OpenWAL(path, true)
			if err != nil {
				t.Fatal(err)
			}
			for i := range 3 {
				if err := w.Append(Record{Key: "k" + string(rune('a'+i)), Value: []byte("v"), Version: Version{uint64(i + 1), "n1"}}); err != nil {
					t.Fatal(err)
				}
			}
			w.Close()
			tt.corrupt(t, path)

			w2, recs, info, err := OpenWAL(path, true)
			if err != nil {
				t.Fatal(err)
			}
			if info.TruncatedBytes == 0 {
				t.Fatal("expected the bad tail to be truncated")
			}
			wantGood := 3
			if tt.name == "flipped bit in last entry" {
				wantGood = 2
			}
			if len(recs) != wantGood {
				t.Fatalf("replayed %d records, want %d", len(recs), wantGood)
			}
			// New appends land after the last good entry and replay cleanly.
			if err := w2.Append(Record{Key: "after", Value: []byte("v"), Version: Version{9, "n1"}}); err != nil {
				t.Fatal(err)
			}
			w2.Close()
			_, recs, info, err = OpenWAL(path, true)
			if err != nil {
				t.Fatal(err)
			}
			if len(recs) != wantGood+1 || info.TruncatedBytes != 0 || recs[len(recs)-1].Key != "after" {
				t.Fatalf("after repair: %d records, truncated %d", len(recs), info.TruncatedBytes)
			}
		})
	}
}

func mustApply(t testing.TB, s *Store, rec Record) {
	t.Helper()
	if _, err := s.Apply(rec); err != nil {
		t.Fatal(err)
	}
}

func fileSize(t *testing.T, path string) int64 {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return st.Size()
}

func appendBytes(t *testing.T, path string, b []byte) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.Write(b); err != nil {
		t.Fatal(err)
	}
}

func BenchmarkApplyMemory(b *testing.B) {
	s, _ := Open(Options{})
	benchApply(b, s)
}

func BenchmarkApplyWALNoSync(b *testing.B) {
	s, err := Open(Options{Dir: b.TempDir(), Logger: quietLogger()})
	if err != nil {
		b.Fatal(err)
	}
	defer s.Close()
	benchApply(b, s)
}

func BenchmarkApplyWALFsync(b *testing.B) {
	s, err := Open(Options{Dir: b.TempDir(), SyncEachWrite: true, Logger: quietLogger()})
	if err != nil {
		b.Fatal(err)
	}
	defer s.Close()
	benchApply(b, s)
}

func benchApply(b *testing.B, s *Store) {
	val := make([]byte, 128)
	b.ReportAllocs()
	b.ResetTimer()
	for i := range b.N {
		key := "key-" + string(rune('a'+i%26))
		if _, err := s.Apply(Record{Key: key, Value: val, Version: Version{uint64(i + 1), "n1"}}); err != nil {
			b.Fatal(err)
		}
	}
}
