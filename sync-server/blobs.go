package main

// Pasteboard data of clippings that hold more than text (images, rich text, an app's own formats) is stored
// beside the logs as blobs/<machine>/<sha256>, named by the SHA-256 of its bytes. A put event lists them in
// "items"; the client uploads a blob before the line that refers to it.
//
//	GET  /v1/blobs/<machine>            ["<sha256>", ...]
//	GET  /v1/blobs/<machine>/<sha256>   the blob
//	HEAD /v1/blobs/<machine>/<sha256>   200 if stored, 404 if not
//	PUT  /v1/blobs/<machine>/<sha256>   store it; 400 unless the body's SHA-256 is the name
//
// Replacing a log removes that machine's blobs the new log no longer refers to.

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const maxBlob = 256 << 20

// Blobs this young survive a log replacement, in case their line is still on its way.
const unreferencedBlobAge = 10 * time.Minute

var blobName = regexp.MustCompile(`^[0-9a-f]{64}$`)

func (s *server) blobDir(machine string) string {
	return filepath.Join(s.dir, "blobs", machine)
}

func (s *server) serveBlobs(w http.ResponseWriter, r *http.Request, rest string) {
	machine, address, _ := strings.Cut(strings.TrimPrefix(rest, "/"), "/")
	if !machineName.MatchString(machine) {
		http.Error(w, "bad machine name", http.StatusBadRequest)
		return
	}
	if address == "" {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		s.listBlobs(w, machine)
		return
	}
	if !blobName.MatchString(address) {
		http.Error(w, "bad blob name", http.StatusBadRequest)
		return
	}
	path := filepath.Join(s.blobDir(machine), address)
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		f, err := os.Open(path)
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, r)
			return
		} else if err != nil {
			http.Error(w, "cannot read blob", http.StatusInternalServerError)
			return
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil {
			http.Error(w, "cannot read blob", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
		if r.Method == http.MethodGet {
			io.Copy(w, f)
		}
	case http.MethodPut:
		s.putBlob(w, r, machine, address, path)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *server) listBlobs(w http.ResponseWriter, machine string) {
	entries, err := os.ReadDir(s.blobDir(machine))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		http.Error(w, "cannot list blobs", http.StatusInternalServerError)
		return
	}
	names := []string{}
	for _, e := range entries {
		if e.Type().IsRegular() && blobName.MatchString(e.Name()) {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(names)
}

// Streamed to a temporary file and hashed on the way, then renamed into place if the hash is the name.
func (s *server) putBlob(w http.ResponseWriter, r *http.Request, machine, address, path string) {
	if err := os.MkdirAll(s.blobDir(machine), 0o700); err != nil {
		http.Error(w, "cannot write blob", http.StatusInternalServerError)
		return
	}
	tmp, err := os.CreateTemp(s.blobDir(machine), "."+address+".*.tmp")
	if err != nil {
		http.Error(w, "cannot write blob", http.StatusInternalServerError)
		return
	}
	defer os.Remove(tmp.Name())
	hash := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, hash), http.MaxBytesReader(w, r.Body, maxBlob)); err != nil {
		tmp.Close()
		http.Error(w, "body too large or unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	if hex.EncodeToString(hash.Sum(nil)) != address {
		tmp.Close()
		http.Error(w, "body does not match its SHA-256 name", http.StatusBadRequest)
		return
	}
	if tmp.Sync() != nil || tmp.Close() != nil || os.Rename(tmp.Name(), path) != nil {
		http.Error(w, "cannot write blob", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// blobAddresses returns every blob address the put events of a log refer to.
func blobAddresses(log []byte) map[string]bool {
	addresses := map[string]bool{}
	scanner := bufio.NewScanner(bytes.NewReader(log))
	scanner.Buffer(make([]byte, 1<<20), maxBody)
	for scanner.Scan() {
		line := scanner.Bytes()
		if !bytes.Contains(line, []byte(`"items"`)) {
			continue
		}
		var event struct {
			Items [][]struct{ B string } `json:"items"`
		}
		if json.Unmarshal(line, &event) != nil {
			continue
		}
		for _, item := range event.Items {
			for _, representation := range item {
				if blobName.MatchString(representation.B) {
					addresses[representation.B] = true
				}
			}
		}
	}
	return addresses
}

// Called with s.mu held, after a log was replaced.
func (s *server) removeUnreferencedBlobs(machine string, log []byte) {
	entries, err := os.ReadDir(s.blobDir(machine))
	if err != nil {
		return
	}
	keep := blobAddresses(log)
	cutoff := time.Now().Add(-unreferencedBlobAge)
	for _, e := range entries {
		if keep[e.Name()] {
			continue
		}
		if info, err := e.Info(); err == nil && info.ModTime().Before(cutoff) {
			os.Remove(filepath.Join(s.blobDir(machine), e.Name()))
		}
	}
}
