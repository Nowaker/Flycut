package main

// The archive: clients search every machine's merged history, beyond what they keep locally.
//
//	GET /v1/archive/search?q=<words>&list=0|1&limit=50&offset=0
//	→ {"matched": N, "clippings": [<put event as stored in its log>, ...]}
//
// The clippings are the live ones of the web history's index (web.go), newest rank first, every copy kept.
// Words match case-insensitively, all of them, against contents, app and machine; a sealed clipping's text
// is never searched. Clients fetch pasteboard data with GET /v1/blobs/<machine>/<sha256> and open sealed
// contents and data themselves.

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
)

const (
	archiveDefaultLimit = 50
	archiveMaxLimit     = 200
)

func (s *server) serveArchive(w http.ResponseWriter, r *http.Request, rest string) {
	if rest != "search" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	index, err := s.web().currentIndex()
	if err != nil {
		http.Error(w, "cannot read the logs", http.StatusInternalServerError)
		return
	}
	q := r.URL.Query()
	list, _ := strconv.Atoi(q.Get("list"))
	if list != 1 {
		list = 0
	}
	limit, err := strconv.Atoi(q.Get("limit"))
	if err != nil || limit <= 0 {
		limit = archiveDefaultLimit
	}
	limit = min(limit, archiveMaxLimit)
	offset, _ := strconv.Atoi(q.Get("offset"))
	offset = max(offset, 0)
	words := strings.Fields(strings.ToLower(q.Get("q")))

	matched := 0
	page := []json.RawMessage{}
	for _, c := range index.lists[list] {
		if !c.matches(words, "") {
			continue
		}
		if matched >= offset && len(page) < limit {
			page = append(page, c.event)
		}
		matched++
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, map[string]any{"matched": matched, "clippings": page})
}
