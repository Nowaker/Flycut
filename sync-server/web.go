package main

// The web history: every machine's history merged the way the clients merge it, browsable at /web/.
//
// Credentials stay masked. The list and detail answers never carry a sealed clipping's text, and
// searching doesn't look inside it, so the page holds no secret until someone clicks Reveal, which
// asks for that one clipping with POST /web/api/reveal. Signing in is in webauth.go.

import (
	"bufio"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"
)

//go:embed web
var webFiles embed.FS

const (
	webPageSize   = 200
	webTitleRunes = 200
)

type logEvent struct {
	V         int                `json:"v"`
	Op        string             `json:"op"`
	List      int                `json:"list"`
	ID        string             `json:"id"`
	At        int64              `json:"at"`
	M         string             `json:"m"`
	Rank      float64            `json:"rank"`
	Contents  *string            `json:"contents"`
	Enc       string             `json:"enc"`
	Type      string             `json:"type"`
	App       string             `json:"app"`
	Ts        int64              `json:"ts"`
	Items     [][]representation `json:"items"`
	Described bool               `json:"described"`
}

// A clipping as the newest event about it left it. Sealed clippings have Enc and no Contents.
type webClipping struct {
	ID, Machine, App, Type, Contents, Enc string
	List                                  int
	At, Ts                                int64
	Rank                                  float64
	Described                             bool
	Items                                 [][]representation
	length                                int
	event                                 json.RawMessage // the put event as stored in its log
}

func (c *webClipping) credential() bool { return c.Enc != "" }

type webIndex struct {
	signature string
	lists     [2][]*webClipping
	byKey     map[string]*webClipping
}

func clipKey(list int, id string) string { return strconv.Itoa(list) + "/" + id }

// Whether a change made at (at, machine) beats one made at (otherAt, otherMachine), as in FlycutFolderSync.
func newer(at int64, machine string, otherAt int64, otherMachine string) bool {
	if at != otherAt {
		return at > otherAt
	}
	return machine > otherMachine
}

func (s *server) logSignature() (string, []string, error) {
	paths, err := filepath.Glob(filepath.Join(s.dir, "*.jsonl"))
	if err != nil {
		return "", nil, err
	}
	sort.Strings(paths)
	var signature strings.Builder
	var logs []string
	for _, path := range paths {
		if !machineName.MatchString(strings.TrimSuffix(filepath.Base(path), ".jsonl")) {
			continue
		}
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		fmt.Fprintf(&signature, "%s:%d:%d;", filepath.Base(path), info.Size(), info.ModTime().UnixNano())
		logs = append(logs, path)
	}
	return signature.String(), logs, nil
}

// buildIndex merges the logs: per clipping the event with the greatest (at, m) wins and a clear removes what
// was last changed before it. Equal clippings are all kept: clients hide duplicates for display, but each copy
// is its own clipping, with its own id, machine and time.
func buildIndex(logs []string, open func(string) (string, error)) (*webIndex, error) {
	type state struct {
		at      int64
		machine string
		clip    *webClipping
	}
	states := map[string]*state{}
	clears := [2]struct {
		at      int64
		machine string
	}{}
	for _, path := range logs {
		f, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 1<<20), maxBody)
		for scanner.Scan() {
			var e logEvent
			if json.Unmarshal(scanner.Bytes(), &e) != nil || e.V != 1 || (e.List != 0 && e.List != 1) {
				continue
			}
			if e.Op == "clear" {
				if newer(e.At, e.M, clears[e.List].at, clears[e.List].machine) {
					clears[e.List].at, clears[e.List].machine = e.At, e.M
				}
				continue
			}
			if e.ID == "" || (e.Op != "put" && e.Op != "del") {
				continue
			}
			key := clipKey(e.List, e.ID)
			if old := states[key]; old != nil && !newer(e.At, e.M, old.at, old.machine) {
				continue
			}
			st := &state{at: e.At, machine: e.M}
			if e.Op == "put" && (e.Contents != nil || e.Enc != "") {
				c := &webClipping{ID: e.ID, Machine: e.M, App: e.App, Type: e.Type, Enc: e.Enc, List: e.List,
					At: e.At, Ts: e.Ts, Rank: e.Rank, Described: e.Described, Items: e.Items,
					event: append(json.RawMessage(nil), scanner.Bytes()...)}
				if e.Contents != nil {
					c.Contents = *e.Contents
				}
				st.clip = c
			}
			states[key] = st
		}
		f.Close()
		if err := scanner.Err(); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	}

	index := &webIndex{byKey: map[string]*webClipping{}}
	for _, st := range states {
		c := st.clip
		if c == nil || !newer(st.at, st.machine, clears[c.List].at, clears[c.List].machine) {
			continue
		}
		index.lists[c.List] = append(index.lists[c.List], c)
	}
	for list := range index.lists {
		clips := index.lists[list]
		sort.Slice(clips, func(i, j int) bool {
			if clips[i].Rank != clips[j].Rank {
				return clips[i].Rank > clips[j].Rank
			}
			return clips[i].ID > clips[j].ID
		})
		kept := clips[:0]
		for _, c := range clips {
			text := c.Contents
			if c.credential() {
				opened, err := open(c.Enc)
				if err != nil {
					continue // sealed with another token: no client can read it either
				}
				text = opened
			}
			c.length = utf8.RuneCountInString(text)
			kept = append(kept, c)
			index.byKey[clipKey(c.List, c.ID)] = c
		}
		index.lists[list] = kept
	}
	return index, nil
}

type webApp struct {
	s        *server
	sealer   *sealer
	mu       sync.Mutex
	index    *webIndex
	auth     *webAuth
	files    fs.FS
	sessions []byte
}

func (s *server) web() *webApp {
	s.webOnce.Do(func() {
		files, _ := fs.Sub(webFiles, "web")
		s.webState = &webApp{s: s, sealer: newSealer(string(s.token)), files: files,
			sessions: hmacSHA256(s.token, []byte("flycut web session v1"))}
		s.webState.auth = newWebAuth(s.dir)
	})
	return s.webState
}

func (a *webApp) currentIndex() (*webIndex, error) {
	signature, logs, err := a.s.logSignature()
	if err != nil {
		return nil, err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.index != nil && a.index.signature == signature {
		return a.index, nil
	}
	index, err := buildIndex(logs, a.sealer.open)
	if err != nil {
		return nil, err
	}
	index.signature = signature
	a.index = index
	return index, nil
}

func setWebHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	// same-origin, not no-referrer: under no-referrer the page's own form posts carry "Origin: null".
	h.Set("Referrer-Policy", "same-origin")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' blob:; script-src 'self'; style-src 'self'; "+
		"frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(value)
}

// serveWeb handles / and /web/...; everything but the sign-in pages and static files needs a session.
func (s *server) serveWeb(w http.ResponseWriter, r *http.Request) {
	a := s.web()
	setWebHeaders(w)
	path := r.URL.Path
	switch path {
	case "/", "/web":
		http.Redirect(w, r, "/web/", http.StatusFound)
		return
	case "/web/login":
		a.auth.serveLogin(w, r, a)
		return
	case "/web/admit":
		a.auth.serveAdmit(w, r, a)
		return
	case "/web/logout":
		if r.Method != http.MethodPost || !sameOrigin(r) {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		a.clearSession(w, r)
		http.Redirect(w, r, "/web/login", http.StatusSeeOther)
		return
	case "/web/app.js", "/web/app.css", "/web/favicon.svg":
		http.ServeFileFS(w, r, a.files, strings.TrimPrefix(path, "/web/"))
		return
	}
	if !a.validSession(r) {
		if strings.HasPrefix(path, "/web/api/") {
			http.Error(w, "not signed in", http.StatusUnauthorized)
		} else {
			http.Redirect(w, r, "/web/login", http.StatusFound)
		}
		return
	}
	switch path {
	case "/web/":
		http.ServeFileFS(w, r, a.files, "index.html")
	case "/web/api/clippings":
		a.serveClippings(w, r)
	case "/web/api/clipping":
		a.serveClipping(w, r)
	case "/web/api/blob":
		a.serveBlob(w, r)
	case "/web/api/reveal":
		a.serveReveal(w, r)
	case "/web/api/reveal-blob":
		a.serveRevealBlob(w, r)
	default:
		http.NotFound(w, r)
	}
}

// Whether a POST came from this site. Browsers send Origin with every POST; a request without one isn't a browser's.
func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	return strings.TrimPrefix(strings.TrimPrefix(origin, "https://"), "http://") == r.Host
}

// A request the page's own script made: same origin, and a header a form or link can't send.
func scriptRequest(r *http.Request) bool {
	return r.Method == http.MethodPost && r.Header.Get("X-Flycut") == "1" && sameOrigin(r)
}

type webListItem struct {
	ID          string `json:"id"`
	List        int    `json:"list"`
	Machine     string `json:"machine"`
	App         string `json:"app,omitempty"`
	Ts          int64  `json:"ts"`
	Title       string `json:"title"`
	Length      int    `json:"length"`
	Credential  bool   `json:"credential,omitempty"`
	Described   bool   `json:"described,omitempty"`
	HasImage    bool   `json:"hasImage,omitempty"`
	FormatCount int    `json:"formats,omitempty"`
}

func titleOf(text string) string {
	text = strings.TrimSpace(text)
	if i := strings.IndexAny(text, "\r\n"); i >= 0 {
		text = text[:i] + " …"
	}
	if utf8.RuneCountInString(text) > webTitleRunes {
		text = string([]rune(text)[:webTitleRunes]) + "…"
	}
	return text
}

func isImageType(t string) bool {
	_, ok := rasterTypes[t]
	return ok
}

// Pasteboard and MIME types browsers show inline. Anything else (SVG, HTML, PDF, an app's own data) is a download.
var rasterTypes = map[string]string{
	"public.png": "image/png", "image/png": "image/png", "public.jpeg": "image/jpeg", "image/jpeg": "image/jpeg",
	"com.compuserve.gif": "image/gif", "image/gif": "image/gif", "org.webmproject.webp": "image/webp",
	"image/webp": "image/webp", "com.microsoft.bmp": "image/bmp", "image/bmp": "image/bmp",
}

func listItem(c *webClipping) webListItem {
	item := webListItem{ID: c.ID, List: c.List, Machine: c.Machine, App: c.App, Ts: c.Ts, Length: c.length,
		Credential: c.credential(), Described: c.Described}
	if !c.credential() {
		item.Title = titleOf(c.Contents)
	}
	for _, it := range c.Items {
		item.FormatCount += len(it)
		for _, r := range it {
			item.HasImage = item.HasImage || (isImageType(r.T) && !r.S)
		}
	}
	return item
}

func (c *webClipping) matches(words []string, machine string) bool {
	if machine != "" && c.Machine != machine {
		return false
	}
	if len(words) == 0 {
		return true
	}
	// A sealed clipping's text isn't searched: matches would tell its text to whoever can search.
	haystack := strings.ToLower(c.App + "\n" + c.Machine)
	if !c.credential() {
		haystack += "\n" + strings.ToLower(c.Contents)
	}
	for _, w := range words {
		if !strings.Contains(haystack, w) {
			return false
		}
	}
	return true
}

func (a *webApp) serveClippings(w http.ResponseWriter, r *http.Request) {
	index, err := a.currentIndex()
	if err != nil {
		http.Error(w, "cannot read the logs", http.StatusInternalServerError)
		return
	}
	q := r.URL.Query()
	list, _ := strconv.Atoi(q.Get("list"))
	if list != 1 {
		list = 0
	}
	offset, _ := strconv.Atoi(q.Get("offset"))
	words := strings.Fields(strings.ToLower(q.Get("q")))
	machine := q.Get("machine")

	machines := map[string]int{}
	var matched []*webClipping
	for _, c := range index.lists[list] {
		machines[c.Machine]++
		if c.matches(words, machine) {
			matched = append(matched, c)
		}
	}
	page := []webListItem{}
	for i := max(offset, 0); i < len(matched) && len(page) < webPageSize; i++ {
		page = append(page, listItem(matched[i]))
	}
	writeJSON(w, map[string]any{"version": index.signature, "total": len(index.lists[list]), "matched": len(matched),
		"offset": offset, "clippings": page, "machines": machines})
}

func (a *webApp) lookup(w http.ResponseWriter, list int, id string) *webClipping {
	index, err := a.currentIndex()
	if err != nil {
		http.Error(w, "cannot read the logs", http.StatusInternalServerError)
		return nil
	}
	c := index.byKey[clipKey(list, id)]
	if c == nil {
		http.Error(w, "no such clipping", http.StatusNotFound)
	}
	return c
}

type webFormat struct {
	T      string `json:"t"`
	N      int64  `json:"n"`
	Sealed bool   `json:"sealed,omitempty"`
	Image  bool   `json:"image,omitempty"`
}

func (a *webApp) serveClipping(w http.ResponseWriter, r *http.Request) {
	list, _ := strconv.Atoi(r.URL.Query().Get("list"))
	c := a.lookup(w, list, r.URL.Query().Get("id"))
	if c == nil {
		return
	}
	formats := [][]webFormat{}
	for _, it := range c.Items {
		item := []webFormat{}
		for _, r := range it {
			item = append(item, webFormat{T: r.T, N: r.N, Sealed: r.S, Image: isImageType(r.T) && !r.S})
		}
		formats = append(formats, item)
	}
	detail := map[string]any{"clipping": listItem(c), "type": c.Type, "formats": formats}
	if !c.credential() {
		detail["text"] = c.Contents
	}
	writeJSON(w, detail)
}

// findRepresentation finds the clipping's item/rep from the query or form, or answers with an error.
func findRepresentation(w http.ResponseWriter, c *webClipping, itemValue, repValue string) *representation {
	item, err1 := strconv.Atoi(itemValue)
	rep, err2 := strconv.Atoi(repValue)
	if err1 != nil || err2 != nil || item < 0 || item >= len(c.Items) || rep < 0 || rep >= len(c.Items[item]) ||
		!blobName.MatchString(c.Items[item][rep].B) {
		http.Error(w, "no such format", http.StatusNotFound)
		return nil
	}
	return &c.Items[item][rep]
}

func downloadName(c *webClipping, r *representation) string {
	name := unsafeFileName.ReplaceAllString(r.T, "_")
	if mime, ok := rasterTypes[r.T]; ok {
		name = "clipping." + strings.TrimPrefix(mime, "image/")
	}
	return fmt.Sprintf("%s-%s", c.ID[:min(8, len(c.ID))], name)
}

func (a *webApp) sendRepresentation(w http.ResponseWriter, c *webClipping, rep *representation, data []byte, download bool) {
	w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
	if mime, ok := rasterTypes[rep.T]; ok && !download {
		w.Header().Set("Content-Type", mime)
	} else {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", downloadName(c, rep)))
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.Write(data)
}

func (a *webApp) serveBlob(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	list, _ := strconv.Atoi(q.Get("list"))
	c := a.lookup(w, list, q.Get("id"))
	if c == nil {
		return
	}
	rep := findRepresentation(w, c, q.Get("item"), q.Get("rep"))
	if rep == nil {
		return
	}
	if rep.S {
		http.Error(w, "sealed: reveal it", http.StatusForbidden)
		return
	}
	data, err := os.ReadFile(filepath.Join(a.s.blobDir(c.Machine), rep.B))
	if err != nil {
		http.Error(w, "the data isn't on the server", http.StatusNotFound)
		return
	}
	a.sendRepresentation(w, c, rep, data, q.Get("download") == "1")
}

type revealRequest struct {
	ID   string `json:"id"`
	List int    `json:"list"`
	Item string `json:"item"`
	Rep  string `json:"rep"`
}

func (a *webApp) revealTarget(w http.ResponseWriter, r *http.Request) (*webClipping, *revealRequest) {
	if !scriptRequest(r) {
		http.Error(w, "reveal from the page", http.StatusForbidden)
		return nil, nil
	}
	var body revealRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return nil, nil
	}
	c := a.lookup(w, body.List, body.ID)
	if c != nil && !c.credential() {
		http.Error(w, "not sealed", http.StatusBadRequest)
		return nil, nil
	}
	return c, &body
}

func remoteOf(r *http.Request) string {
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		return forwarded
	}
	return r.RemoteAddr
}

func (a *webApp) serveReveal(w http.ResponseWriter, r *http.Request) {
	c, _ := a.revealTarget(w, r)
	if c == nil {
		return
	}
	text, err := a.sealer.open(c.Enc)
	if err != nil {
		http.Error(w, "cannot open it", http.StatusInternalServerError)
		return
	}
	log.Printf("web: revealed clipping %s (list %d, from %s) to %s", c.ID, c.List, c.Machine, remoteOf(r))
	writeJSON(w, map[string]string{"text": text})
}

func (a *webApp) serveRevealBlob(w http.ResponseWriter, r *http.Request) {
	c, body := a.revealTarget(w, r)
	if c == nil {
		return
	}
	rep := findRepresentation(w, c, body.Item, body.Rep)
	if rep == nil {
		return
	}
	data, err := os.ReadFile(filepath.Join(a.s.blobDir(c.Machine), rep.B))
	if err == nil && rep.S {
		data, err = a.sealer.openData(data)
	}
	if err != nil {
		http.Error(w, "cannot open it", http.StatusNotFound)
		return
	}
	log.Printf("web: revealed %s data of clipping %s (list %d) to %s", rep.T, c.ID, c.List, remoteOf(r))
	a.sendRepresentation(w, c, rep, data, true)
}
