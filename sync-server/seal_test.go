package main

import (
	"bytes"
	"crypto/rand"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestSealOpen(t *testing.T) {
	s := newSealer("qa-token-for-sealing")
	nonce := make([]byte, 16)
	rand.Read(nonce)
	plaintext := "hasło: Zażółć gęślą jaźń, longer than one AES block"
	sealed := s.seal(plaintext, nonce)
	if got, err := s.open(sealed); err != nil || got != plaintext {
		t.Fatalf("round trip: %q %v", got, err)
	}
	if _, err := newSealer("another-token").open(sealed); err == nil {
		t.Fatal("another token opened it")
	}
	tampered := []byte(sealed)
	tampered[10] ^= 1
	if _, err := s.open(string(tampered)); err == nil {
		t.Fatal("tampered text opened")
	}
}

// Writes go.sealed and opens the other implementations' sealed text when FLYCUT_INTEROP_DIR points at it.
func TestInterop(t *testing.T) {
	dir := os.Getenv("FLYCUT_INTEROP_DIR")
	if dir == "" {
		t.Skip("FLYCUT_INTEROP_DIR not set")
	}
	s := newSealer("interop-token-0123456789abcdef")
	plaintext := "interop: Zażółć gęślą jaźń, three AES blocks or so of text to cross the counter boundary twice."
	nonce := make([]byte, 16)
	rand.Read(nonce)
	os.WriteFile(filepath.Join(dir, "go.sealed"), []byte(s.seal(plaintext, nonce)), 0o600)
	for _, name := range []string{"objc.sealed", "python.sealed"} {
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got, err := s.open(strings.TrimSpace(string(raw))); err != nil || got != plaintext {
			t.Errorf("%s: %v", name, err)
		}
	}
	// Blob sealing is deterministic, so every implementation must produce the same bytes.
	blob := []byte(plaintext + "\x00\x01\xfe\xff")
	os.WriteFile(filepath.Join(dir, "go.blob"), s.sealData(blob), 0o600)
	for _, name := range []string{"objc.blob", "python.blob"} {
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if !bytes.Equal(raw, s.sealData(blob)) {
			t.Errorf("%s differs from Go's sealed blob", name)
		}
		if got, err := s.openData(raw); err != nil || !bytes.Equal(got, blob) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestSealedClippings(t *testing.T) {
	dir := t.TempDir()
	s := newSealer("t")
	nonce := make([]byte, 16)
	put := func(id string, at int, enc string) string {
		return `{"v":1,"op":"put","list":0,"id":"` + id + `","at":` + strconv.Itoa(at) + `,"m":"mac","enc":"` + enc + `","ts":0}` + "\n"
	}
	os.WriteFile(filepath.Join(dir, "mac.jsonl"), []byte(
		put("A", 1, s.seal("first", nonce))+
			put("B", 2, s.seal("second", nonce))+
			`{"v":1,"op":"del","list":0,"id":"A","at":3,"m":"mac"}`+"\n"+
			`{"v":1,"op":"put","list":0,"id":"C","at":4,"m":"mac","contents":"plain"}`+"\n"), 0o600)
	list, err := sealedClippings(dir)
	if err != nil || len(list) != 1 || list[0].ID != "B" {
		t.Fatalf("got %+v %v", list, err)
	}
	if text, _ := s.open(list[0].Enc); text != "second" {
		t.Fatalf("opened %q", text)
	}
}
