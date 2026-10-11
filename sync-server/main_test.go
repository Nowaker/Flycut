package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var testToken = strings.Repeat("t", 20)

func newTestServer(t *testing.T) (*httptest.Server, string) {
	dir := t.TempDir()
	ts := httptest.NewServer(&server{dir: dir, token: []byte(testToken)})
	t.Cleanup(ts.Close)
	return ts, dir
}

func do(t *testing.T, ts *httptest.Server, method, path, body string, headers map[string]string) (*http.Response, string) {
	t.Helper()
	req, _ := http.NewRequest(method, ts.URL+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+testToken)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, string(data)
}

func TestAppendReadAndList(t *testing.T) {
	ts, dir := newTestServer(t)
	line1 := `{"v":1,"op":"put","id":"a"}` + "\n"
	line2 := `{"v":1,"op":"del","id":"a"}` + "\n"

	if resp, _ := do(t, ts, "POST", "/v1/logs/mac-1", line1, map[string]string{"X-Log-Offset": "0"}); resp.StatusCode != 204 {
		t.Fatalf("first append: %d", resp.StatusCode)
	}
	resp, _ := do(t, ts, "POST", "/v1/logs/mac-1", line2, map[string]string{"X-Log-Offset": "0"})
	if resp.StatusCode != 409 || resp.Header.Get("X-Log-Size") != "28" {
		t.Fatalf("stale offset: %d size %s", resp.StatusCode, resp.Header.Get("X-Log-Size"))
	}
	if resp, _ := do(t, ts, "POST", "/v1/logs/mac-1", line2, map[string]string{"X-Log-Offset": "28"}); resp.StatusCode != 204 || resp.Header.Get("X-Log-Size") != "56" {
		t.Fatalf("second append: %d", resp.StatusCode)
	}

	resp, body := do(t, ts, "GET", "/v1/logs/mac-1?from=28", "", nil)
	if body != line2 || resp.Header.Get("X-Log-Size") != "56" {
		t.Fatalf("read from offset: %q size %s", body, resp.Header.Get("X-Log-Size"))
	}
	if _, body := do(t, ts, "GET", "/v1/logs/mac-1?from=999", "", nil); body != line1+line2 {
		t.Fatalf("offset past the end reads everything: %q", body)
	}

	_, body = do(t, ts, "GET", "/v1/logs", "", nil)
	var logs []logInfo
	json.Unmarshal([]byte(body), &logs)
	if len(logs) != 1 || logs[0].Machine != "mac-1" || logs[0].Size != 56 {
		t.Fatalf("list: %s", body)
	}

	info, _ := os.Stat(filepath.Join(dir, "mac-1.jsonl"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("log mode %o", info.Mode().Perm())
	}
}

func TestReplace(t *testing.T) {
	ts, _ := newTestServer(t)
	do(t, ts, "POST", "/v1/logs/mac-1", "{\"a\":1}\n{\"a\":2}\n", nil)
	if resp, _ := do(t, ts, "PUT", "/v1/logs/mac-1", "{\"a\":2}\n", nil); resp.StatusCode != 204 {
		t.Fatalf("replace: %d", resp.StatusCode)
	}
	if _, body := do(t, ts, "GET", "/v1/logs/mac-1", "", nil); body != "{\"a\":2}\n" {
		t.Fatalf("after replace: %q", body)
	}
}

func TestRejects(t *testing.T) {
	ts, _ := newTestServer(t)
	cases := []struct {
		method, path, body string
		status             int
	}{
		{"POST", "/v1/logs/mac-1", `{"a":1}`, 400},
		{"POST", "/v1/logs/mac-1", "not json\n", 400},
		{"POST", "/v1/logs/mac-1", "[1,2]\n", 400},
		{"POST", "/v1/logs/..%2Fescape", "{}\n", 400},
		{"GET", "/v1/logs/nobody", "", 404},
		{"DELETE", "/v1/logs/mac-1", "", 405},
		{"GET", "/other", "", 404},
	}
	for _, c := range cases {
		if resp, _ := do(t, ts, c.method, c.path, c.body, nil); resp.StatusCode != c.status {
			t.Errorf("%s %s %q: got %d, want %d", c.method, c.path, c.body, resp.StatusCode, c.status)
		}
	}

	req, _ := http.NewRequest("GET", ts.URL+"/v1/logs", nil)
	req.Header.Set("Authorization", "Bearer wrong-token-wrong-token")
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 401 {
		t.Errorf("wrong token: %d", resp.StatusCode)
	}
}

func TestListenAddresses(t *testing.T) {
	for addr, ok := range map[string]bool{
		"127.0.0.1:8742":             true,
		"100.105.229.19:8742":        true,
		"[::1]:8742":                 true,
		"localhost:8742":             true,
		"127.0.0.1:8742, [::1]:8742": true,
		"127.0.0.1:8742,:8742":       false,
		"0.0.0.0:8742":               false,
		":8742":                      false,
		"[::]:8742":                  false,
	} {
		if addrs, err := listenAddresses(addr); (err == nil) != ok || (ok && len(addrs) == 0) {
			t.Errorf("%s: %v %v", addr, addrs, err)
		}
	}
	if addrs, _ := listenAddresses("localhost:8742"); len(addrs) == 0 || addrs[0] == "localhost:8742" {
		t.Errorf("a name is resolved to addresses: %v", addrs)
	}
}
