package main

// Signing in to the web history. Two ways, both ending in a session cookie:
//
//   - A one-time admission link: Flycut asks for one with its token (POST /v1/web/admission) and opens it
//     in the browser. It works once, within two minutes. This is the only way in until a password is set.
//   - A login and password, optional, set from Flycut (PUT /v1/web/login; the login may be empty). Stored as
//     PBKDF2-SHA256 in web-login.json beside the logs. Setting one doesn't turn admission links off.
//
// The session cookie is the expiry signed with a key derived from the token, so it survives a restart and
// a new token ends every session.

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"html/template"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	sessionCookie       = "flycut_web"
	sessionLifetime     = 12 * time.Hour
	admissionLifetime   = 2 * time.Minute
	maxAdmissions       = 64
	passwordIterations  = 600_000
	loginFailureWindow  = 15 * time.Minute
	maxLoginFailures    = 10
	webLoginFileName    = "web-login.json"
	maxPasswordBodySize = 4096
)

var loginPage = template.Must(template.ParseFS(webFiles, "web/login.html"))

type webLogin struct {
	Login      string `json:"login"`
	Salt       []byte `json:"salt"`
	Iterations int    `json:"iterations"`
	Hash       []byte `json:"hash"`
}

type webAuth struct {
	path       string
	mu         sync.Mutex
	admissions map[string]time.Time
	failures   []time.Time
}

func newWebAuth(dir string) *webAuth {
	return &webAuth{path: filepath.Join(dir, webLoginFileName), admissions: map[string]time.Time{}}
}

// RFC 8018 PBKDF2 with HMAC-SHA256.
func pbkdf2SHA256(password, salt []byte, iterations, keyLength int) []byte {
	prf := hmac.New(sha256.New, password)
	var out []byte
	for block := uint32(1); len(out) < keyLength; block++ {
		prf.Reset()
		prf.Write(salt)
		prf.Write([]byte{byte(block >> 24), byte(block >> 16), byte(block >> 8), byte(block)})
		u := prf.Sum(nil)
		t := append([]byte{}, u...)
		for i := 1; i < iterations; i++ {
			prf.Reset()
			prf.Write(u)
			u = prf.Sum(u[:0])
			for j := range t {
				t[j] ^= u[j]
			}
		}
		out = append(out, t...)
	}
	return out[:keyLength]
}

func (a *webAuth) storedLogin() *webLogin {
	raw, err := os.ReadFile(a.path)
	if err != nil {
		return nil
	}
	var l webLogin
	if json.Unmarshal(raw, &l) != nil || len(l.Hash) == 0 || l.Iterations < 1 {
		return nil
	}
	return &l
}

func (a *webAuth) setLogin(login, password string) error {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return err
	}
	raw, _ := json.Marshal(webLogin{Login: login, Salt: salt, Iterations: passwordIterations,
		Hash: pbkdf2SHA256([]byte(password), salt, passwordIterations, 32)})
	tmp := a.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.path)
}

func (a *webAuth) removeLogin() error {
	if err := os.Remove(a.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (a *webAuth) checkPassword(login, password string) bool {
	l := a.storedLogin()
	if l == nil {
		return false
	}
	hash := pbkdf2SHA256([]byte(password), l.Salt, l.Iterations, len(l.Hash))
	loginOK := subtle.ConstantTimeCompare([]byte(login), []byte(l.Login)) == 1
	return subtle.ConstantTimeCompare(hash, l.Hash) == 1 && loginOK
}

// Too many wrong passwords lately: the form refuses for a while, whoever is guessing.
func (a *webAuth) lockedOut() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	cutoff := time.Now().Add(-loginFailureWindow)
	kept := a.failures[:0]
	for _, t := range a.failures {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	a.failures = kept
	return len(a.failures) >= maxLoginFailures
}

func (a *webAuth) noteFailure() {
	a.mu.Lock()
	a.failures = append(a.failures, time.Now())
	a.mu.Unlock()
}

func (a *webAuth) newAdmission() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	code := base64.RawURLEncoding.EncodeToString(raw)
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	for c, expiry := range a.admissions {
		if now.After(expiry) {
			delete(a.admissions, c)
		}
	}
	if len(a.admissions) >= maxAdmissions {
		return "", errors.New("too many admission links waiting to be used")
	}
	a.admissions[code] = now.Add(admissionLifetime)
	return code, nil
}

func (a *webAuth) useAdmission(code string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	expiry, ok := a.admissions[code]
	delete(a.admissions, code)
	return ok && time.Now().Before(expiry)
}

func secureRequest(r *http.Request) bool {
	return r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https"
}

func (w *webApp) sessionValue(expiry int64) string {
	e := strconv.FormatInt(expiry, 10)
	return e + "." + hex.EncodeToString(hmacSHA256(w.sessions, []byte("session|"+e)))
}

func (w *webApp) setSession(rw http.ResponseWriter, r *http.Request) {
	expiry := time.Now().Add(sessionLifetime)
	http.SetCookie(rw, &http.Cookie{Name: sessionCookie, Value: w.sessionValue(expiry.Unix()), Path: "/web/",
		Expires: expiry, HttpOnly: true, Secure: secureRequest(r), SameSite: http.SameSiteLaxMode})
}

func (w *webApp) clearSession(rw http.ResponseWriter, r *http.Request) {
	http.SetCookie(rw, &http.Cookie{Name: sessionCookie, Value: "", Path: "/web/", MaxAge: -1,
		HttpOnly: true, Secure: secureRequest(r), SameSite: http.SameSiteLaxMode})
}

func (w *webApp) validSession(r *http.Request) bool {
	cookie, err := r.Cookie(sessionCookie)
	if err != nil {
		return false
	}
	e, _, ok := strings.Cut(cookie.Value, ".")
	expiry, err := strconv.ParseInt(e, 10, 64)
	if !ok || err != nil || time.Now().Unix() >= expiry {
		return false
	}
	return hmac.Equal([]byte(cookie.Value), []byte(w.sessionValue(expiry)))
}

type loginView struct {
	HasPassword bool
	Login       string
	Error       string
}

func (a *webAuth) renderLogin(w http.ResponseWriter, view loginView, status int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	loginPage.Execute(w, view)
}

func (a *webAuth) serveLogin(w http.ResponseWriter, r *http.Request, app *webApp) {
	stored := a.storedLogin()
	view := loginView{HasPassword: stored != nil}
	if r.Method == http.MethodGet {
		if app.validSession(r) {
			http.Redirect(w, r, "/web/", http.StatusFound)
			return
		}
		a.renderLogin(w, view, http.StatusOK)
		return
	}
	if r.Method != http.MethodPost || !sameOrigin(r) {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if stored == nil {
		a.renderLogin(w, view, http.StatusForbidden)
		return
	}
	if a.lockedOut() {
		view.Error = "Too many wrong passwords. Wait a few minutes, or open the history from Flycut."
		a.renderLogin(w, view, http.StatusTooManyRequests)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxPasswordBodySize)
	login, password := r.PostFormValue("login"), r.PostFormValue("password")
	if !a.checkPassword(login, password) {
		a.noteFailure()
		view.Login, view.Error = login, "Wrong login or password."
		a.renderLogin(w, view, http.StatusUnauthorized)
		return
	}
	app.setSession(w, r)
	http.Redirect(w, r, "/web/", http.StatusSeeOther)
}

func (a *webAuth) serveAdmit(w http.ResponseWriter, r *http.Request, app *webApp) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !a.useAdmission(r.URL.Query().Get("code")) {
		view := loginView{HasPassword: a.storedLogin() != nil,
			Error: "This link was already used or has expired. Open the history from Flycut again."}
		a.renderLogin(w, view, http.StatusForbidden)
		return
	}
	app.setSession(w, r)
	http.Redirect(w, r, "/web/", http.StatusSeeOther)
}

// serveWebSettings is the bearer-token side: /v1/web/admission and /v1/web/login.
func (s *server) serveWebSettings(w http.ResponseWriter, r *http.Request, rest string) {
	a := s.web().auth
	switch rest {
	case "admission":
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		code, err := a.newAdmission()
		if err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		writeJSON(w, map[string]string{"path": "/web/admit?code=" + code})
	case "login":
		switch r.Method {
		case http.MethodGet:
			stored := a.storedLogin()
			login := ""
			if stored != nil {
				login = stored.Login
			}
			writeJSON(w, map[string]any{"login": login, "password": stored != nil})
		case http.MethodPut:
			var body struct{ Login, Password string }
			if json.NewDecoder(http.MaxBytesReader(w, r.Body, maxPasswordBodySize)).Decode(&body) != nil || body.Password == "" {
				http.Error(w, "send {\"login\": ..., \"password\": ...} with a password", http.StatusBadRequest)
				return
			}
			if err := a.setLogin(body.Login, body.Password); err != nil {
				http.Error(w, "cannot store the password", http.StatusInternalServerError)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		case http.MethodDelete:
			if err := a.removeLogin(); err != nil {
				http.Error(w, "cannot remove the password", http.StatusInternalServerError)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	default:
		http.NotFound(w, r)
	}
}
