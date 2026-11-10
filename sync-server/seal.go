package main

// Clients seal credential clippings before they reach the server: a put event then carries "enc" instead of
// "contents", in the format of FlycutEngine/FlycutSyncCrypto.h, keyed by the server token. The server never
// needs to open them; `flycut-sync-server reveal` does, for whoever holds the token file.

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type sealer struct {
	encryptionKey, macKey []byte
}

func hmacSHA256(key, message []byte) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write(message)
	return mac.Sum(nil)
}

func newSealer(token string) *sealer {
	prk := hmacSHA256([]byte("flycut-sync"), []byte(token))
	var okm, block []byte
	for counter := byte(1); counter <= 2; counter++ {
		block = hmacSHA256(prk, append(append(append([]byte{}, block...), "clipping contents v1"...), counter))
		okm = append(okm, block...)
	}
	return &sealer{encryptionKey: okm[:32], macKey: okm[32:64]}
}

func (s *sealer) ctr(nonce, data []byte) []byte {
	block, _ := aes.NewCipher(s.encryptionKey)
	out := make([]byte, len(data))
	cipher.NewCTR(block, nonce).XORKeyStream(out, data)
	return out
}

func (s *sealer) tag(nonce, ciphertext []byte) []byte {
	return hmacSHA256(s.macKey, append(append([]byte("flycut-v1"), nonce...), ciphertext...))
}

func (s *sealer) seal(plaintext string, nonce []byte) string {
	ciphertext := s.ctr(nonce, []byte(plaintext))
	sealed := append(append(append([]byte{}, nonce...), ciphertext...), s.tag(nonce, ciphertext)...)
	return "v1:" + base64.StdEncoding.EncodeToString(sealed)
}

func (s *sealer) open(sealed string) (string, error) {
	encoded, ok := strings.CutPrefix(sealed, "v1:")
	if !ok {
		return "", errors.New("not a v1 sealed clipping")
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(data) < 48 {
		return "", errors.New("malformed sealed clipping")
	}
	nonce, ciphertext, tag := data[:16], data[16:len(data)-32], data[len(data)-32:]
	if !hmac.Equal(tag, s.tag(nonce, ciphertext)) {
		return "", errors.New("sealed with another token, or altered")
	}
	return string(s.ctr(nonce, ciphertext)), nil
}

type sealedClipping struct {
	Machine, ID, App, Enc string
	At, Timestamp         int64
}

// The newest put of every clipping whose newest put is sealed, oldest first.
func sealedClippings(dir string) ([]sealedClipping, error) {
	logs, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	if err != nil {
		return nil, err
	}
	latest := map[string]sealedClipping{}
	seen := map[string]int64{}
	for _, path := range logs {
		f, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 1<<20), maxBody)
		for scanner.Scan() {
			var event struct {
				Op, ID, M, App, Enc string
				List                int
				At, Ts              int64
			}
			if json.Unmarshal(scanner.Bytes(), &event) != nil || event.ID == "" || event.At < seen[event.ID] {
				continue
			}
			seen[event.ID] = event.At
			delete(latest, event.ID)
			if event.Op == "put" && event.Enc != "" {
				latest[event.ID] = sealedClipping{Machine: event.M, ID: event.ID, App: event.App, Enc: event.Enc, At: event.At, Timestamp: event.Ts}
			}
		}
		f.Close()
		if err := scanner.Err(); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	}
	list := make([]sealedClipping, 0, len(latest))
	for _, c := range latest {
		list = append(list, c)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].At < list[j].At })
	return list, nil
}

// reveal lists the sealed clippings in the logs, or prints the one with -id.
func reveal(args []string) error {
	flags := flag.NewFlagSet("reveal", flag.ExitOnError)
	dataDir := flags.String("data", "", "directory holding the logs")
	tokenFile := flags.String("token-file", "", "file containing the server token the clients seal with")
	id := flags.String("id", "", "print this clipping's contents; without it, list the sealed clippings")
	flags.Usage = func() {
		fmt.Fprintln(flags.Output(), "usage: flycut-sync-server reveal -data DIR -token-file FILE [-id CLIPPING-ID]")
		flags.PrintDefaults()
	}
	flags.Parse(args)
	if *dataDir == "" || *tokenFile == "" {
		flags.Usage()
		os.Exit(2)
	}
	raw, err := os.ReadFile(*tokenFile)
	if err != nil {
		return err
	}
	s := newSealer(strings.TrimSpace(string(raw)))
	list, err := sealedClippings(*dataDir)
	if err != nil {
		return err
	}
	for _, c := range list {
		if *id == "" {
			text, err := s.open(c.Enc)
			length := fmt.Sprintf("%d characters", len([]rune(text)))
			if err != nil {
				length = err.Error()
			}
			fmt.Printf("%s  %s  %-28s %-20s %s\n", time.Unix(c.Timestamp, 0).Format("2006-01-02 15:04"), c.ID, c.Machine, c.App, length)
		} else if c.ID == *id {
			text, err := s.open(c.Enc)
			if err != nil {
				return err
			}
			fmt.Println(text)
			return nil
		}
	}
	if *id != "" {
		return fmt.Errorf("no sealed clipping %s", *id)
	}
	return nil
}
