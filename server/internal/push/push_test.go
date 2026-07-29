package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sideshow/apns2/token"
)

// testKeyPEM returns a PKCS#8 PEM block of the same shape as Apple's .p8 — a
// P-256 ECDSA private key. Generating one keeps the fixture out of the repo and
// lets the assertions go all the way through apns2's own parser, so a test can
// only pass if the bytes would really have configured a client.
func testKeyPEM(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func TestAPNsKeyBytesAcceptsEveryEncoding(t *testing.T) {
	pemKey := testKeyPEM(t)

	cases := []struct {
		name    string
		content string
	}{
		{"raw PEM", pemKey},
		{"PEM with surrounding whitespace", "\n  " + pemKey + "  \n"},
		{"PEM with literal backslash-n", strings.ReplaceAll(pemKey, "\n", `\n`)},
		{"PEM with literal backslash-r-backslash-n", strings.ReplaceAll(pemKey, "\n", `\r\n`)},
		{"base64 of the PEM", base64.StdEncoding.EncodeToString([]byte(pemKey))},
		{"base64 wrapped across lines", wrap(base64.StdEncoding.EncodeToString([]byte(pemKey)), 64)},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := apnsKeyBytes(tc.content, "")
			if err != nil {
				t.Fatalf("apnsKeyBytes: %v", err)
			}
			// The real bar: apns2 must accept it as a signing key.
			if _, err := token.AuthKeyFromBytes(got); err != nil {
				t.Fatalf("apns2 rejected the resolved key: %v", err)
			}
		})
	}
}

func TestAPNsKeyBytesReadsPathWhenContentUnset(t *testing.T) {
	pemKey := testKeyPEM(t)
	path := filepath.Join(t.TempDir(), "AuthKey_ABCDE12345.p8")
	if err := os.WriteFile(path, []byte(pemKey), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}

	got, err := apnsKeyBytes("", path)
	if err != nil {
		t.Fatalf("apnsKeyBytes: %v", err)
	}
	if string(got) != pemKey {
		t.Fatal("path form did not return the file contents verbatim")
	}
}

func TestAPNsKeyBytesPrefersContentOverPath(t *testing.T) {
	content := testKeyPEM(t)
	path := filepath.Join(t.TempDir(), "stale.p8")
	if err := os.WriteFile(path, []byte("-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----\n"), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}

	got, err := apnsKeyBytes(content, path)
	if err != nil {
		t.Fatalf("apnsKeyBytes: %v", err)
	}
	if strings.TrimSpace(string(got)) != strings.TrimSpace(content) {
		t.Fatal("content should win over path; a stale bind-mounted file must not shadow it")
	}
	// And the file's contents are genuinely unusable, so this would have failed
	// loudly had the precedence gone the other way.
	if _, err := token.AuthKeyFromBytes(got); err != nil {
		t.Fatalf("apns2 rejected the resolved key: %v", err)
	}
}

func TestAPNsKeyBytesUnsetIsNotAnError(t *testing.T) {
	// Push disabled is a supported state, so neither source set must read as
	// "not configured" rather than as a failure to be logged.
	got, err := apnsKeyBytes("", "")
	if err != nil {
		t.Fatalf("unset should not error, got %v", err)
	}
	if got != nil {
		t.Fatalf("unset should return nil bytes, got %d", len(got))
	}
	// Whitespace-only content is the shape an empty compose variable produces.
	got, err = apnsKeyBytes("   \n  ", "")
	if err != nil || got != nil {
		t.Fatalf("blank content should behave as unset, got %v / %v", got, err)
	}
}

func TestAPNsKeyBytesRejectsGarbage(t *testing.T) {
	if _, err := apnsKeyBytes("this is not a key at all !!", ""); err == nil {
		t.Fatal("expected an error for content that is neither PEM nor base64")
	}
	// Valid base64 that decodes to something other than a PEM key: the failure
	// must name the real problem rather than surfacing later as a parse error.
	notPEM := base64.StdEncoding.EncodeToString([]byte("hello there"))
	_, err := apnsKeyBytes(notPEM, "")
	if err == nil || !strings.Contains(err.Error(), "not a PEM key") {
		t.Fatalf("expected a not-a-PEM-key error, got %v", err)
	}
}

func TestAPNsKeyBytesMissingFileErrors(t *testing.T) {
	if _, err := apnsKeyBytes("", filepath.Join(t.TempDir(), "absent.p8")); err == nil {
		t.Fatal("expected an error when the configured path does not exist")
	}
}

func wrap(s string, n int) string {
	var b strings.Builder
	for i := 0; i < len(s); i += n {
		end := min(i+n, len(s))
		b.WriteString(s[i:end])
		b.WriteString("\n")
	}
	return b.String()
}
