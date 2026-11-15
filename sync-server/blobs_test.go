package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func address(data string) string {
	sum := sha256.Sum256([]byte(data))
	return hex.EncodeToString(sum[:])
}

func TestBlobs(t *testing.T) {
	ts, dir := newTestServer(t)
	png := "\x89PNG fake image bytes"
	a := address(png)

	if resp, _ := do(t, ts, "HEAD", "/v1/blobs/mac-1/"+a, "", nil); resp.StatusCode != 404 {
		t.Fatalf("head before put: %d", resp.StatusCode)
	}
	if resp, _ := do(t, ts, "PUT", "/v1/blobs/mac-1/"+a, png+"x", nil); resp.StatusCode != 400 {
		t.Fatalf("mismatched body: %d", resp.StatusCode)
	}
	if resp, _ := do(t, ts, "PUT", "/v1/blobs/mac-1/"+a, png, nil); resp.StatusCode != 204 {
		t.Fatalf("put: %d", resp.StatusCode)
	}
	if resp, body := do(t, ts, "GET", "/v1/blobs/mac-1/"+a, "", nil); resp.StatusCode != 200 || body != png {
		t.Fatalf("get: %d %q", resp.StatusCode, body)
	}
	if resp, _ := do(t, ts, "HEAD", "/v1/blobs/mac-1/"+a, "", nil); resp.StatusCode != 200 {
		t.Fatalf("head after put: %d", resp.StatusCode)
	}
	if _, body := do(t, ts, "GET", "/v1/blobs/mac-1", "", nil); body != `["`+a+`"]`+"\n" {
		t.Fatalf("list: %q", body)
	}
	if _, body := do(t, ts, "GET", "/v1/blobs/nobody", "", nil); body != "[]\n" {
		t.Fatalf("empty list: %q", body)
	}
	for _, path := range []string{"/v1/blobs/mac-1/ABC", "/v1/blobs/..%2Fx/" + a, "/v1/blobs/mac-1/" + a + "/x"} {
		if resp, _ := do(t, ts, "GET", path, "", nil); resp.StatusCode != 400 {
			t.Errorf("%s: %d", path, resp.StatusCode)
		}
	}
	info, _ := os.Stat(filepath.Join(dir, "blobs", "mac-1", a))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("blob mode %o", info.Mode().Perm())
	}
	// The logs listing still shows only logs.
	if _, body := do(t, ts, "GET", "/v1/logs", "", nil); body != "[]\n" {
		t.Fatalf("logs: %q", body)
	}
}

func TestReplaceRemovesUnreferencedBlobs(t *testing.T) {
	ts, dir := newTestServer(t)
	kept, dropped, young := address("kept"), address("dropped"), address("young")
	for _, data := range []string{"kept", "dropped", "young"} {
		do(t, ts, "PUT", "/v1/blobs/mac-1/"+address(data), data, nil)
	}
	old := time.Now().Add(-time.Hour)
	for _, a := range []string{kept, dropped} {
		os.Chtimes(filepath.Join(dir, "blobs", "mac-1", a), old, old)
	}
	log := `{"v":1,"op":"put","id":"a","items":[[{"t":"public.png","b":"` + kept + `","n":4}]]}` + "\n"
	if resp, _ := do(t, ts, "PUT", "/v1/logs/mac-1", log, nil); resp.StatusCode != 204 {
		t.Fatalf("replace: %d", resp.StatusCode)
	}
	for a, want := range map[string]bool{kept: true, dropped: false, young: true} {
		if _, err := os.Stat(filepath.Join(dir, "blobs", "mac-1", a)); (err == nil) != want {
			t.Errorf("%s present=%v, want %v", a, err == nil, want)
		}
	}
}

func TestSealData(t *testing.T) {
	s := newSealer("qa-token-for-sealing")
	data := bytes.Repeat([]byte{0, 1, 2, 0xff}, 100)
	sealed := s.sealData(data)
	if !bytes.Equal(sealed, s.sealData(data)) {
		t.Fatal("equal data sealed differently")
	}
	if bytes.Contains(sealed, data[:16]) {
		t.Fatal("plaintext visible")
	}
	if got, err := s.openData(sealed); err != nil || !bytes.Equal(got, data) {
		t.Fatalf("round trip: %v", err)
	}
	sealed[20] ^= 1
	if _, err := s.openData(sealed); err == nil {
		t.Fatal("tampered blob opened")
	}
}
