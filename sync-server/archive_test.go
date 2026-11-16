package main

import (
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type archivePage struct {
	Matched   int
	Clippings []json.RawMessage
}

func archiveSearch(t *testing.T, do func(string) (*http.Response, string), query string) archivePage {
	t.Helper()
	resp, body := do("/v1/archive/search?" + query)
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Content-Type") != "application/json" {
		t.Fatalf("%s: %d %s", query, resp.StatusCode, body)
	}
	var page archivePage
	if err := json.Unmarshal([]byte(body), &page); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	return page
}

func eventIDs(t *testing.T, page archivePage) string {
	var ids []string
	for _, raw := range page.Clippings {
		var e logEvent
		if err := json.Unmarshal(raw, &e); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, e.ID)
	}
	return strings.Join(ids, ",")
}

func TestArchiveSearch(t *testing.T) {
	ts, dir := newTestServer(t)
	s := newSealer(testToken)
	writeLogs(t, dir, s, []byte("\x89PNG\r\n\x1a\nfake-image-bytes"))
	get := func(path string) (*http.Response, string) { return do(t, ts, "GET", path, "", nil) }

	// Everything live, newest rank first, duplicates kept, clear/del/stale applied.
	all := archiveSearch(t, get, "")
	if ids := eventIDs(t, all); ids != "SEC,IMG,A1,B1,DUP" || all.Matched != 5 {
		t.Fatalf("all: %d %s", all.Matched, ids)
	}

	// Each element is the put event exactly as its log stores it.
	macLog, _ := os.ReadFile(filepath.Join(dir, "mac-a.jsonl"))
	linuxLog, _ := os.ReadFile(filepath.Join(dir, "linux-b.jsonl"))
	logged := "\n" + string(macLog) + string(linuxLog)
	for _, raw := range all.Clippings {
		if !strings.Contains(logged, "\n"+string(raw)+"\n") {
			t.Fatalf("not as stored: %s", raw)
		}
	}
	if !strings.Contains(string(all.Clippings[1]), `"items":[[{"t":"public.png","b":"`) {
		t.Fatalf("image event lost its items: %s", all.Clippings[1])
	}

	// Words are AND-matched, case-insensitively, against contents, app and machine.
	cases := map[string]string{
		"q=ALPHA":                         "A1,DUP",
		"q=alpha+terminal":                "A1",
		"q=" + url.QueryEscape("LINUX-b"): "B1,DUP",
		"q=alpha+linux":                   "DUP",
		"q=alpha+nothing":                 "",
		"q=a+favorite&list=1":             "FAV",
		"q=a+favorite":                    "",
	}
	for query, want := range cases {
		if got := eventIDs(t, archiveSearch(t, get, query)); got != want {
			t.Errorf("%s: got %q, want %q", query, got, want)
		}
	}

	// A sealed clipping is never matched on its text, and its text never leaves the server open.
	for _, word := range []string{"ghp_Q7", webSecret, "code"} {
		if page := archiveSearch(t, get, "q="+url.QueryEscape(word)); page.Matched != 0 {
			t.Errorf("sealed text searched for %q: %s", word, eventIDs(t, page))
		}
	}
	if _, body := get("/v1/archive/search"); strings.Contains(body, webSecret) || !strings.Contains(body, `"enc":"v1:`) {
		t.Fatal("sealed clipping must come back sealed")
	}
	if got := eventIDs(t, archiveSearch(t, get, "q=mac-a")); got != "SEC,IMG,A1" {
		t.Fatalf("sealed clipping still matches on machine: %s", got)
	}

	// Paging: limit, offset, and a cap of 200.
	if page := archiveSearch(t, get, "limit=2&offset=1"); eventIDs(t, page) != "IMG,A1" || page.Matched != 5 {
		t.Fatalf("page: %d %s", page.Matched, eventIDs(t, page))
	}
	if page := archiveSearch(t, get, "offset=9"); len(page.Clippings) != 0 || page.Matched != 5 {
		t.Fatalf("past the end: %+v", page)
	}
	f, _ := os.OpenFile(filepath.Join(dir, "linux-b.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	for i := 0; i < 250; i++ {
		f.WriteString(`{"v":1,"op":"put","list":0,"id":"BULK` + strings.Repeat("x", i) + `","at":300,"m":"linux-b","rank":1,"contents":"bulk","ts":0}` + "\n")
	}
	f.Close()
	if page := archiveSearch(t, get, "q=bulk&limit=1000"); len(page.Clippings) != archiveMaxLimit || page.Matched != 250 {
		t.Fatalf("limit cap: %d of %d", len(page.Clippings), page.Matched)
	}
	if page := archiveSearch(t, get, "q=bulk"); len(page.Clippings) != archiveDefaultLimit {
		t.Fatalf("default limit: %d", len(page.Clippings))
	}
}

func TestArchiveAuth(t *testing.T) {
	ts, dir := newTestServer(t)
	writeLogs(t, dir, newSealer(testToken), []byte("png"))
	for _, auth := range []string{"", "Bearer wrong-token-0123456789", "Basic " + testToken} {
		req, _ := http.NewRequest("GET", ts.URL+"/v1/archive/search?q=alpha", nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%q: %d", auth, resp.StatusCode)
		}
	}
	// A web session is not enough: the archive answers the token only.
	b := &browser{t: t, ts: ts}
	b.admit()
	if resp, _ := b.do("GET", "/v1/archive/search?q=alpha", "", nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("with a web session: %d", resp.StatusCode)
	}
	if resp, _ := do(t, ts, "POST", "/v1/archive/search", "", nil); resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST: %d", resp.StatusCode)
	}
	if resp, _ := do(t, ts, "GET", "/v1/archive/other", "", nil); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown archive path: %d", resp.StatusCode)
	}
}
