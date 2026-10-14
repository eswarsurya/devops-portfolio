package store

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// Each WAL entry is framed as:
//
//	uint32 payload length | uint32 CRC-32C of payload | payload (JSON Record)
//
// The checksum lets replay tell a complete entry from one that was cut
// short by a crash mid-write.
const (
	frameHeader  = 8
	maxFrameSize = 16 << 20
)

var crcTable = crc32.MakeTable(crc32.Castagnoli)

// WAL is an append-only log of records on disk.
type WAL struct {
	mu       sync.Mutex
	f        *os.File
	path     string
	syncEach bool
}

// ReplayInfo describes what OpenWAL found on disk.
type ReplayInfo struct {
	Entries        int   // complete entries read
	TruncatedBytes int64 // bytes of a torn or corrupt tail that were cut off
}

// OpenWAL opens (or creates) the log at path and returns every complete
// record in it, oldest first. A torn or corrupt tail is truncated so new
// entries are appended after the last good one. With syncEach set, every
// Append calls fsync before returning.
func OpenWAL(path string, syncEach bool) (*WAL, []Record, ReplayInfo, error) {
	var info ReplayInfo
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, nil, info, fmt.Errorf("open wal: %w", err)
	}
	recs, good, err := readFrames(f)
	if err != nil {
		f.Close()
		return nil, nil, info, err
	}
	info.Entries = len(recs)
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, info, fmt.Errorf("stat wal: %w", err)
	}
	if st.Size() > good {
		info.TruncatedBytes = st.Size() - good
		if err := f.Truncate(good); err != nil {
			f.Close()
			return nil, nil, info, fmt.Errorf("truncate torn wal tail: %w", err)
		}
		if err := f.Sync(); err != nil {
			f.Close()
			return nil, nil, info, fmt.Errorf("sync wal: %w", err)
		}
	}
	if _, err := f.Seek(good, io.SeekStart); err != nil {
		f.Close()
		return nil, nil, info, fmt.Errorf("seek wal: %w", err)
	}
	return &WAL{f: f, path: path, syncEach: syncEach}, recs, info, nil
}

// readFrames reads complete frames from the start of f. It returns the
// records and the offset just after the last good frame. A short or
// corrupt frame ends the read without an error: that is what a crash in
// the middle of an append looks like.
func readFrames(f *os.File) ([]Record, int64, error) {
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, 0, fmt.Errorf("seek wal: %w", err)
	}
	r := bufio.NewReader(f)
	var (
		recs []Record
		good int64
		hdr  [frameHeader]byte
	)
	for {
		if _, err := io.ReadFull(r, hdr[:]); err != nil {
			return recs, good, nil // clean EOF or torn header
		}
		n := binary.BigEndian.Uint32(hdr[0:4])
		sum := binary.BigEndian.Uint32(hdr[4:8])
		if n == 0 || n > maxFrameSize {
			return recs, good, nil
		}
		payload := make([]byte, n)
		if _, err := io.ReadFull(r, payload); err != nil {
			return recs, good, nil
		}
		if crc32.Checksum(payload, crcTable) != sum {
			return recs, good, nil
		}
		var rec Record
		if err := json.Unmarshal(payload, &rec); err != nil {
			return recs, good, nil
		}
		recs = append(recs, rec)
		good += int64(frameHeader) + int64(n)
	}
}

func encodeFrame(rec Record) ([]byte, error) {
	payload, err := json.Marshal(rec)
	if err != nil {
		return nil, err
	}
	buf := make([]byte, frameHeader+len(payload))
	binary.BigEndian.PutUint32(buf[0:4], uint32(len(payload)))
	binary.BigEndian.PutUint32(buf[4:8], crc32.Checksum(payload, crcTable))
	copy(buf[frameHeader:], payload)
	return buf, nil
}

// Append writes one record. With syncEach it is on stable storage when
// Append returns.
func (w *WAL) Append(rec Record) error {
	buf, err := encodeFrame(rec)
	if err != nil {
		return fmt.Errorf("encode wal entry: %w", err)
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return errors.New("wal is closed")
	}
	if _, err := w.f.Write(buf); err != nil {
		return fmt.Errorf("write wal: %w", err)
	}
	if w.syncEach {
		if err := w.f.Sync(); err != nil {
			return fmt.Errorf("fsync wal: %w", err)
		}
	}
	return nil
}

// Rewrite replaces the log with exactly the given records. It writes a
// temporary file, fsyncs it and renames it over the old log, so a crash
// leaves either the old log or the new one, never a mix.
func (w *WAL) Rewrite(recs []Record) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	tmp := w.path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("create compacted wal: %w", err)
	}
	bw := bufio.NewWriter(f)
	for _, rec := range recs {
		buf, err := encodeFrame(rec)
		if err == nil {
			_, err = bw.Write(buf)
		}
		if err != nil {
			f.Close()
			os.Remove(tmp)
			return fmt.Errorf("write compacted wal: %w", err)
		}
	}
	if err := bw.Flush(); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("flush compacted wal: %w", err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("fsync compacted wal: %w", err)
	}
	if err := os.Rename(tmp, w.path); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("replace wal: %w", err)
	}
	syncDir(filepath.Dir(w.path))
	if w.f != nil {
		w.f.Close()
	}
	if _, err := f.Seek(0, io.SeekEnd); err != nil {
		f.Close()
		w.f = nil
		return fmt.Errorf("seek compacted wal: %w", err)
	}
	w.f = f
	return nil
}

// syncDir makes a rename durable. Errors are ignored: some filesystems do
// not support fsync on directories.
func syncDir(dir string) {
	d, err := os.Open(dir)
	if err != nil {
		return
	}
	_ = d.Sync()
	d.Close()
}

// Close syncs and closes the log.
func (w *WAL) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return nil
	}
	err := w.f.Sync()
	if cerr := w.f.Close(); err == nil {
		err = cerr
	}
	w.f = nil
	return err
}
