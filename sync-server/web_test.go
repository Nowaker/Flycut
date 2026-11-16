package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Made up for this test, and assembled so secret scanners don't take it for a real token.
var webSecret = "ghp" + "_" + strings.Repeat("Q7xLm2Vt9R", 3) + "kZpWa1"

// browser is a cookie-keeping client that doesn't follow redirects.
type browser struct {
	t      *testing.T
	ts     *httptest.Server
	cookie string
}

func (b *browser) do(method, path, body string, headers map[string]string) (*http.Response, string) {
	b.t.Helper()
	req, _ := http.NewRequest(method, b.ts.URL+path, strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if b.cookie != "" {
		req.Header.Set("Cookie", sessionCookie+"="+b.cookie)
	}
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		b.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	for _, c := range resp.Cookies() {
		if c.Name == sessionCookie {
			b.cookie = c.Value
		}
	}
	return resp, string(data)
}

func (b *browser) admit() {
	b.t.Helper()
	_, body := do(b.t, b.ts, "POST", "/v1/web/admission", "", nil)
	var admission struct{ Path string }
	json.Unmarshal([]byte(body), &admission)
	if resp, _ := b.do("GET", admission.Path, "", nil); resp.StatusCode != http.StatusSeeOther || b.cookie == "" {
		b.t.Fatalf("admission: %d", resp.StatusCode)
	}
}

func TestPBKDF2Vector(t *testing.T) {
	// RFC 7914 section 11, PBKDF2-HMAC-SHA256 with P="passwd", S="salt", c=1, dkLen=64.
	want := "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
	if got := hex.EncodeToString(pbkdf2SHA256([]byte("passwd"), []byte("salt"), 1, 64)); got != want {
		t.Fatalf("got %s", got)
	}
}

func TestWebSignIn(t *testing.T) {
	ts, dir := newTestServer(t)
	b := &browser{t: t, ts: ts}

	if resp, _ := b.do("GET", "/", "", nil); resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/web/" {
		t.Fatalf("root: %d %s", resp.StatusCode, resp.Header.Get("Location"))
	}
	if resp, _ := b.do("GET", "/web/", "", nil); resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/web/login" {
		t.Fatalf("signed out page: %d", resp.StatusCode)
	}
	if resp, _ := b.do("GET", "/web/api/clippings", "", nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("signed out api: %d", resp.StatusCode)
	}
	if _, body := b.do("GET", "/web/login", "", nil); !strings.Contains(body, "Open History in Browser") || strings.Contains(body, `type="password"`) {
		t.Fatalf("without a password the login page points at Flycut: %s", body)
	}
	if resp, _ := b.do("POST", "/web/login", "login=&password=x", map[string]string{"Content-Type": "application/x-www-form-urlencoded"}); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("password login without a password set: %d", resp.StatusCode)
	}

	// Admission links: only with the token, once.
	if resp, _ := b.do("POST", "/v1/web/admission", "", nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("admission without the token: %d", resp.StatusCode)
	}
	_, body := do(t, ts, "POST", "/v1/web/admission", "", nil)
	var admission struct{ Path string }
	json.Unmarshal([]byte(body), &admission)
	if resp, _ := b.do("GET", admission.Path, "", nil); resp.StatusCode != http.StatusSeeOther || b.cookie == "" {
		t.Fatalf("admission: %d", resp.StatusCode)
	}
	if resp, _ := b.do("GET", "/web/", "", nil); resp.StatusCode != http.StatusOK {
		t.Fatalf("signed in page: %d", resp.StatusCode)
	}
	other := &browser{t: t, ts: ts}
	if resp, _ := other.do("GET", admission.Path, "", nil); resp.StatusCode != http.StatusForbidden || other.cookie != "" {
		t.Fatalf("second use of a link: %d", resp.StatusCode)
	}

	// A forged or expired cookie is no session.
	forged := &browser{t: t, ts: ts, cookie: strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10) + ".00"}
	if resp, _ := forged.do("GET", "/web/api/clippings", "", nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("forged cookie: %d", resp.StatusCode)
	}
	app := (&server{dir: dir, token: []byte(testToken)}).web()
	expired := &browser{t: t, ts: ts, cookie: app.sessionValue(time.Now().Add(-time.Minute).Unix())}
	if resp, _ := expired.do("GET", "/web/api/clippings", "", nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expired cookie: %d", resp.StatusCode)
	}

	// Login and password, set with the token; the login may be empty.
	if resp, _ := do(t, ts, "PUT", "/v1/web/login", `{"login":"","password":"correct horse"}`, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("set password: %d", resp.StatusCode)
	}
	if _, body := do(t, ts, "GET", "/v1/web/login", "", nil); body != `{"login":"","password":true}`+"\n" {
		t.Fatalf("login settings: %s", body)
	}
	raw, _ := os.ReadFile(filepath.Join(dir, webLoginFileName))
	if strings.Contains(string(raw), "correct horse") {
		t.Fatal("password stored in plain text")
	}
	if info, _ := os.Stat(filepath.Join(dir, webLoginFileName)); info.Mode().Perm() != 0o600 {
		t.Fatalf("login file mode %o", info.Mode().Perm())
	}
	form := map[string]string{"Content-Type": "application/x-www-form-urlencoded"}
	guest := &browser{t: t, ts: ts}
	if _, body := guest.do("GET", "/web/login", "", nil); !strings.Contains(body, `type="password"`) {
		t.Fatal("with a password the login page has the form")
	}
	if resp, _ := guest.do("POST", "/web/login", "login=&password=wrong", form); resp.StatusCode != http.StatusUnauthorized || guest.cookie != "" {
		t.Fatalf("wrong password: %d", resp.StatusCode)
	}
	if resp, _ := guest.do("POST", "/web/login", "login=&password="+url.QueryEscape("correct horse"), form); resp.StatusCode != http.StatusSeeOther || guest.cookie == "" {
		t.Fatalf("right password: %d", resp.StatusCode)
	}
	if resp, _ := (&browser{t: t, ts: ts}).do("POST", "/web/login", "login=x&password=correct+horse", form); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong login: %d", resp.StatusCode)
	}
	for _, origin := range []string{"https://evil.example", "null"} {
		if resp, _ := guest.do("POST", "/web/login", "login=&password=x", map[string]string{"Content-Type": "application/x-www-form-urlencoded", "Origin": origin}); resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("login post from origin %s: %d", origin, resp.StatusCode)
		}
	}
	// Admission still works with a password set.
	(&browser{t: t, ts: ts}).admit()

	if resp, _ := do(t, ts, "DELETE", "/v1/web/login", "", nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("remove password: %d", resp.StatusCode)
	}
	if resp, _ := (&browser{t: t, ts: ts}).do("POST", "/web/login", "login=&password=correct+horse", form); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("password login after removing it: %d", resp.StatusCode)
	}
	if resp, _ := guest.do("POST", "/web/logout", "", nil); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("logout: %d", resp.StatusCode)
	}
}

func TestWebLockout(t *testing.T) {
	ts, _ := newTestServer(t)
	do(t, ts, "PUT", "/v1/web/login", `{"login":"me","password":"pw"}`, nil)
	form := map[string]string{"Content-Type": "application/x-www-form-urlencoded"}
	b := &browser{t: t, ts: ts}
	for i := 0; i < maxLoginFailures; i++ {
		b.do("POST", "/web/login", "login=me&password=no", form)
	}
	if resp, _ := b.do("POST", "/web/login", "login=me&password=pw", form); resp.StatusCode != http.StatusTooManyRequests || b.cookie != "" {
		t.Fatalf("after %d failures: %d", maxLoginFailures, resp.StatusCode)
	}
}

func writeLogs(t *testing.T, dir string, s *sealer, png []byte) (sealedHTML []byte) {
	t.Helper()
	nonce := make([]byte, 16)
	rand.Read(nonce)
	html := []byte("<code>" + webSecret + "</code>")
	sealedBlob := s.sealData(html)
	os.MkdirAll(filepath.Join(dir, "blobs", "mac-a"), 0o700)
	os.WriteFile(filepath.Join(dir, "blobs", "mac-a", address(string(png))), png, 0o600)
	os.WriteFile(filepath.Join(dir, "blobs", "mac-a", address(string(sealedBlob))), sealedBlob, 0o600)
	now := time.Now().Unix()
	lines := func(events ...string) []byte { return []byte(strings.Join(events, "\n") + "\n") }
	os.WriteFile(filepath.Join(dir, "mac-a.jsonl"), lines(
		`{"v":1,"op":"put","list":0,"id":"OLD","at":1,"m":"mac-a","rank":1,"contents":"before the clear","ts":1}`,
		`{"v":1,"op":"put","list":0,"id":"A1","at":100,"m":"mac-a","rank":10,"contents":"alpha first line\nsecond","app":"Terminal","ts":`+strconv.FormatInt(now, 10)+`}`,
		`{"v":1,"op":"put","list":0,"id":"IMG","at":101,"m":"mac-a","rank":11,"contents":"[image: PNG, 2×2, 70 bytes]","described":true,"ts":0,`+
			`"items":[[{"t":"public.png","b":"`+address(string(png))+`","n":`+strconv.Itoa(len(png))+`}]]}`,
		`{"v":1,"op":"put","list":0,"id":"SEC","at":102,"m":"mac-a","rank":12,"enc":"`+s.seal(webSecret, nonce)+`","ts":0,`+
			`"items":[[{"t":"public.html","b":"`+address(string(sealedBlob))+`","n":`+strconv.Itoa(len(html))+`,"s":true}]]}`,
		`{"v":1,"op":"put","list":1,"id":"FAV","at":103,"m":"mac-a","rank":5,"contents":"a favorite","ts":0}`,
		`{"v":1,"op":"put","list":0,"id":"GONE","at":104,"m":"mac-a","rank":13,"contents":"deleted later","ts":0}`,
	), 0o600)
	os.WriteFile(filepath.Join(dir, "linux-b.jsonl"), lines(
		`{"v":1,"op":"clear","list":0,"at":50,"m":"linux-b"}`,
		`{"v":1,"op":"put","list":0,"id":"B1","at":105,"m":"linux-b","rank":9,"contents":"beta from linux","ts":0}`,
		`{"v":1,"op":"put","list":0,"id":"DUP","at":106,"m":"linux-b","rank":8,"contents":"alpha first line\nsecond","ts":0}`,
		`{"v":1,"op":"del","list":0,"id":"GONE","at":107,"m":"linux-b"}`,
		`not json`,
		`{"v":1,"op":"put","list":0,"id":"A1","at":99,"m":"linux-b","rank":99,"contents":"stale edit","ts":0}`,
	), 0o600)
	return html
}

func TestWebHistory(t *testing.T) {
	ts, dir := newTestServer(t)
	s := newSealer(testToken)
	png := []byte("\x89PNG\r\n\x1a\nfake-image-bytes")
	html := writeLogs(t, dir, s, png)
	b := &browser{t: t, ts: ts}
	b.admit()

	resp, body := b.do("GET", "/web/api/clippings?list=0", "", nil)
	if resp.Header.Get("Cache-Control") != "no-store" || !strings.Contains(resp.Header.Get("Content-Security-Policy"), "script-src 'self'") {
		t.Fatalf("headers: %v", resp.Header)
	}
	var page struct {
		Total, Matched int
		Clippings      []webListItem
		Machines       map[string]int
	}
	json.Unmarshal([]byte(body), &page)
	var ids []string
	for _, c := range page.Clippings {
		ids = append(ids, c.ID)
	}
	if strings.Join(ids, ",") != "SEC,IMG,A1,B1,DUP" {
		t.Fatalf("merged, newest rank first, clear/del/stale applied, duplicates kept: %v", ids)
	}
	if strings.Contains(body, webSecret) || strings.Contains(body, "<code>") {
		t.Fatal("the list carries the credential")
	}
	sec := page.Clippings[0]
	if !sec.Credential || sec.Title != "" || sec.Length != len(webSecret) {
		t.Fatalf("credential row: %+v", sec)
	}
	if page.Clippings[2].Title != "alpha first line …" || page.Clippings[1].HasImage != true || page.Machines["mac-a"] != 3 {
		t.Fatalf("rows: %+v %v", page.Clippings, page.Machines)
	}

	if _, body := b.do("GET", "/web/api/clippings?list=0&q="+url.QueryEscape("ghp_Q7"), "", nil); strings.Contains(body, `"SEC"`) {
		t.Fatal("search looks inside sealed text")
	}
	if _, body := b.do("GET", "/web/api/clippings?list=0&q=BETA+linux", "", nil); !strings.Contains(body, `"id":"B1"`) || strings.Contains(body, `"A1"`) {
		t.Fatalf("search: %s", body)
	}
	if _, body := b.do("GET", "/web/api/clippings?list=0&machine=linux-b", "", nil); !strings.Contains(body, `"matched":2`) {
		t.Fatalf("machine filter: %s", body)
	}
	if _, body := b.do("GET", "/web/api/clippings?list=1", "", nil); !strings.Contains(body, `"id":"FAV"`) {
		t.Fatalf("favorites: %s", body)
	}

	if _, body := b.do("GET", "/web/api/clipping?list=0&id=SEC", "", nil); strings.Contains(body, webSecret) || strings.Contains(body, `"text"`) {
		t.Fatalf("credential detail carries text: %s", body)
	}
	if _, body := b.do("GET", "/web/api/clipping?list=0&id=A1", "", nil); !strings.Contains(body, `"text":"alpha first line\nsecond"`) {
		t.Fatalf("detail: %s", body)
	}

	// Revealing takes a POST from the page itself.
	reveal := `{"list":0,"id":"SEC"}`
	if resp, _ := b.do("GET", "/web/api/reveal?list=0&id=SEC", "", nil); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("reveal by GET: %d", resp.StatusCode)
	}
	if resp, _ := b.do("POST", "/web/api/reveal", reveal, nil); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("reveal without the page's header: %d", resp.StatusCode)
	}
	if resp, _ := b.do("POST", "/web/api/reveal", reveal, map[string]string{"X-Flycut": "1", "Origin": "https://evil.example"}); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("cross-site reveal: %d", resp.StatusCode)
	}
	if resp, _ := (&browser{t: t, ts: ts}).do("POST", "/web/api/reveal", reveal, map[string]string{"X-Flycut": "1"}); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("reveal signed out: %d", resp.StatusCode)
	}
	if _, body := b.do("POST", "/web/api/reveal", reveal, map[string]string{"X-Flycut": "1"}); body != `{"text":"`+webSecret+`"}`+"\n" {
		t.Fatalf("reveal: %s", body)
	}
	if resp, _ := b.do("POST", "/web/api/reveal", `{"list":0,"id":"A1"}`, map[string]string{"X-Flycut": "1"}); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("reveal of a plain clipping: %d", resp.StatusCode)
	}

	// Pasteboard data: images inline, sealed data only through reveal.
	resp, body = b.do("GET", "/web/api/blob?list=0&id=IMG&item=0&rep=0", "", nil)
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "image/png" || body != string(png) || !strings.Contains(resp.Header.Get("Content-Security-Policy"), "sandbox") {
		t.Fatalf("image: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if resp, _ := b.do("GET", "/web/api/blob?list=0&id=IMG&item=0&rep=0&download=1", "", nil); !strings.HasPrefix(resp.Header.Get("Content-Disposition"), "attachment") {
		t.Fatalf("download: %v", resp.Header)
	}
	if resp, _ := b.do("GET", "/web/api/blob?list=0&id=SEC&item=0&rep=0", "", nil); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("sealed blob by GET: %d", resp.StatusCode)
	}
	for _, q := range []string{"id=IMG&item=1&rep=0", "id=IMG&item=0&rep=5", "id=NOPE&item=0&rep=0", "id=IMG&item=x&rep=0"} {
		if resp, _ := b.do("GET", "/web/api/blob?list=0&"+q, "", nil); resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s: %d", q, resp.StatusCode)
		}
	}
	resp, body = b.do("POST", "/web/api/reveal-blob", `{"list":0,"id":"SEC","item":"0","rep":"0"}`, map[string]string{"X-Flycut": "1"})
	if resp.StatusCode != 200 || body != string(html) || !strings.HasPrefix(resp.Header.Get("Content-Disposition"), "attachment") {
		t.Fatalf("reveal blob: %d %q", resp.StatusCode, body)
	}

	// Static files and the page don't carry data.
	for _, path := range []string{"/web/", "/web/app.js", "/web/app.css", "/web/favicon.svg"} {
		if resp, body := b.do("GET", path, "", nil); resp.StatusCode != 200 || strings.Contains(body, "alpha first") {
			t.Errorf("%s: %d", path, resp.StatusCode)
		}
	}

	// A new line shows up without restarting.
	f, _ := os.OpenFile(filepath.Join(dir, "linux-b.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"v":1,"op":"put","list":0,"id":"NEW","at":200,"m":"linux-b","rank":50,"contents":"just copied","ts":0}` + "\n")
	f.Close()
	if _, body := b.do("GET", "/web/api/clippings?list=0", "", nil); !strings.Contains(body, `"clippings":[{"id":"NEW"`) {
		t.Fatalf("after an append: %s", body)
	}
}
