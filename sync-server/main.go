// flycut-sync-server keeps Flycut clipboard history logs for a user's machines.
//
// It stores exactly what the folder sync stores in a shared folder: one append-only
// <machine>.jsonl per machine, each line one JSON event. The server never interprets
// events beyond checking that each line is a JSON object; merging happens in the clients.
//
//	GET  /v1/logs                    [{"machine":"m4max-1a2b3c4d","size":1234}, ...]
//	GET  /v1/logs/<machine>?from=N   the log's bytes from offset N; X-Log-Size has the full size
//	POST /v1/logs/<machine>          append complete lines; 409 with X-Log-Size if X-Log-Offset isn't the current size
//	PUT  /v1/logs/<machine>          replace the log (after a client compacts it)
//
// Every request needs "Authorization: Bearer <token>", the token read from -token-file.
package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxBody = 64 << 20

var machineName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

type server struct {
	dir   string
	token []byte
	mu    sync.Mutex // serializes writes; reads go through the filesystem
}

func (s *server) path(machine string) string {
	return filepath.Join(s.dir, machine+".jsonl")
}

func (s *server) authorized(r *http.Request) bool {
	given, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && subtle.ConstantTimeCompare([]byte(given), s.token) == 1
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	rest, ok := strings.CutPrefix(r.URL.Path, "/v1/logs")
	switch {
	case !ok:
		http.NotFound(w, r)
	case rest == "" || rest == "/":
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		s.list(w)
	default:
		machine := strings.TrimPrefix(rest, "/")
		if !machineName.MatchString(machine) {
			http.Error(w, "bad machine name", http.StatusBadRequest)
			return
		}
		switch r.Method {
		case http.MethodGet:
			s.read(w, r, machine)
		case http.MethodPost:
			s.append(w, r, machine)
		case http.MethodPut:
			s.replace(w, r, machine)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	}
}

type logInfo struct {
	Machine string `json:"machine"`
	Size    int64  `json:"size"`
}

func (s *server) list(w http.ResponseWriter) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		http.Error(w, "cannot list logs", http.StatusInternalServerError)
		return
	}
	logs := []logInfo{}
	for _, e := range entries {
		machine, ok := strings.CutSuffix(e.Name(), ".jsonl")
		if !ok || !e.Type().IsRegular() || !machineName.MatchString(machine) {
			continue
		}
		if info, err := e.Info(); err == nil {
			logs = append(logs, logInfo{machine, info.Size()})
		}
	}
	sort.Slice(logs, func(i, j int) bool { return logs[i].Machine < logs[j].Machine })
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(logs)
}

func (s *server) read(w http.ResponseWriter, r *http.Request, machine string) {
	from, _ := strconv.ParseInt(r.URL.Query().Get("from"), 10, 64)
	f, err := os.Open(s.path(machine))
	if errors.Is(err, os.ErrNotExist) {
		http.NotFound(w, r)
		return
	} else if err != nil {
		http.Error(w, "cannot read log", http.StatusInternalServerError)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		http.Error(w, "cannot read log", http.StatusInternalServerError)
		return
	}
	if from < 0 || from > info.Size() {
		from = 0
	}
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("X-Log-Size", strconv.FormatInt(info.Size(), 10))
	f.Seek(from, io.SeekStart)
	io.CopyN(w, f, info.Size()-from)
}

// Only whole lines that are JSON objects are stored, so a reader never gets half an event.
func validLines(body []byte) error {
	if len(body) == 0 {
		return nil
	}
	if body[len(body)-1] != '\n' {
		return errors.New("body must end with a newline")
	}
	for i, line := range bytes.Split(body[:len(body)-1], []byte("\n")) {
		var event map[string]any
		if err := json.Unmarshal(line, &event); err != nil {
			return fmt.Errorf("line %d is not a JSON object", i+1)
		}
	}
	return nil
}

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		http.Error(w, "body too large or unreadable", http.StatusRequestEntityTooLarge)
		return nil, false
	}
	if err := validLines(body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return nil, false
	}
	return body, true
}

// Appends are conditional on the client's idea of the current size, so a retried request
// can't store the same lines twice and a client whose copy was replaced finds out.
func (s *server) append(w http.ResponseWriter, r *http.Request, machine string) {
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	f, err := os.OpenFile(s.path(machine), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		http.Error(w, "cannot write log", http.StatusInternalServerError)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		http.Error(w, "cannot write log", http.StatusInternalServerError)
		return
	}
	size := info.Size()
	if expected := r.Header.Get("X-Log-Offset"); expected != "" && expected != strconv.FormatInt(size, 10) {
		w.Header().Set("X-Log-Size", strconv.FormatInt(size, 10))
		http.Error(w, "offset mismatch", http.StatusConflict)
		return
	}
	if _, err := f.Write(body); err != nil {
		http.Error(w, "cannot write log", http.StatusInternalServerError)
		return
	}
	if err := f.Sync(); err != nil {
		http.Error(w, "cannot write log", http.StatusInternalServerError)
		return
	}
	w.Header().Set("X-Log-Size", strconv.FormatInt(size+int64(len(body)), 10))
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) replace(w http.ResponseWriter, r *http.Request, machine string) {
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tmp, err := os.CreateTemp(s.dir, "."+machine+".*.tmp")
	if err != nil {
		http.Error(w, "cannot write log", http.StatusInternalServerError)
		return
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(body); err != nil || tmp.Sync() != nil || tmp.Close() != nil {
		http.Error(w, "cannot write log", http.StatusInternalServerError)
		return
	}
	if err := os.Rename(tmp.Name(), s.path(machine)); err != nil {
		http.Error(w, "cannot write log", http.StatusInternalServerError)
		return
	}
	w.Header().Set("X-Log-Size", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusNoContent)
}

// Clipboard history is private, so the server must not answer on every interface.
func checkListenAddress(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if host == "" || (ip != nil && ip.IsUnspecified()) {
		return fmt.Errorf("refusing to listen on all interfaces (%q); give a loopback or Tailscale address", addr)
	}
	return nil
}

func main() {
	listen := flag.String("listen", "127.0.0.1:8742", "address to listen on (loopback or a Tailscale address)")
	dataDir := flag.String("data", "", "directory holding the logs")
	tokenFile := flag.String("token-file", "", "file containing the bearer token clients must send")
	flag.Parse()

	if *dataDir == "" || *tokenFile == "" {
		log.Fatal("-data and -token-file are required")
	}
	if err := checkListenAddress(*listen); err != nil {
		log.Fatal(err)
	}
	raw, err := os.ReadFile(*tokenFile)
	if err != nil {
		log.Fatalf("cannot read token: %v", err)
	}
	token := bytes.TrimSpace(raw)
	if len(token) < 16 {
		log.Fatal("token must be at least 16 characters")
	}
	if err := os.MkdirAll(*dataDir, 0o700); err != nil {
		log.Fatal(err)
	}

	srv := &http.Server{
		Addr:              *listen,
		Handler:           &server{dir: *dataDir, token: token},
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("flycut-sync-server listening on %s, logs in %s", *listen, *dataDir)
	log.Fatal(srv.ListenAndServe())
}
