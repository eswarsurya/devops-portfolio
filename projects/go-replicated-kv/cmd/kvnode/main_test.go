package main

import (
	"reflect"
	"testing"
)

func TestParsePeers(t *testing.T) {
	tests := []struct {
		in      string
		want    map[string]string
		wantErr bool
	}{
		{"", map[string]string{}, false},
		{"kv2=http://kv2:7070, kv3=http://kv3:7070/", map[string]string{"kv2": "http://kv2:7070", "kv3": "http://kv3:7070"}, false},
		{"kv2", nil, true},
		{"kv2=kv2:7070", nil, true},
		{"kv2=http://a,kv2=http://b", nil, true},
	}
	for _, tt := range tests {
		got, err := parsePeers(tt.in)
		if (err != nil) != tt.wantErr {
			t.Fatalf("parsePeers(%q) error = %v, wantErr %v", tt.in, err, tt.wantErr)
		}
		if !tt.wantErr && !reflect.DeepEqual(got, tt.want) {
			t.Fatalf("parsePeers(%q) = %v, want %v", tt.in, got, tt.want)
		}
	}
}

func TestFlagsOverrideEnv(t *testing.T) {
	t.Setenv("KV_NODE_ID", "from-env")
	t.Setenv("KV_W", "3")
	o, err := parseFlags([]string{"-node-id", "from-flag"})
	if err != nil {
		t.Fatal(err)
	}
	if o.nodeID != "from-flag" || o.w != 3 {
		t.Fatalf("got node %q w %d", o.nodeID, o.w)
	}
	t.Setenv("KV_NODE_ID", "")
	if _, err := parseFlags(nil); err == nil {
		t.Fatal("missing node id accepted")
	}
}
