package profile

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// A display name is drawn in the connection switcher, the timeline, the member
// list and the push copy. A newline or a tab in one breaks the layout of all four,
// so the sanitiser is the only thing standing between a typed name and that.
func TestSanitise(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
	}{
		{"plain", "Kieran", "Kieran"},
		{"trims", "   Kieran   ", "Kieran"},
		{"collapses internal runs", "Kieran    O'Neill", "Kieran O'Neill"},
		{"strips tabs and newlines", "Kieran\tO'Neill\nJr", "Kieran O'Neill Jr"},
		{"strips carriage returns", "Kieran\r\nO'Neill", "Kieran O'Neill"},
		{"strips control characters", "Kie\x00ran\x07", "Kieran"},
		{"empty stays empty", "", ""},
		{"whitespace only becomes empty", " \t\n ", ""},
		// Emoji and non-Latin scripts are names too, and must survive.
		{"keeps emoji", "Kieran 🍐", "Kieran 🍐"},
		{"keeps non-latin", "김기란", "김기란"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := sanitise(tc.input); got != tc.want {
				t.Fatalf("sanitise(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

// The column is 80 characters, and truncating by byte would split a multi-byte
// character into invalid UTF-8 — which would then fail to encode as JSON.
func TestSanitiseTruncatesByRuneNotByte(t *testing.T) {
	// Each of these is 3 bytes, so 80 of them is 240 bytes.
	long := strings.Repeat("한", 100)

	got := sanitise(long)

	if count := utf8.RuneCountInString(got); count != maxDisplayNameLength {
		t.Fatalf("got %d runes, want %d", count, maxDisplayNameLength)
	}
	if !utf8.ValidString(got) {
		t.Fatal("truncation produced invalid UTF-8")
	}
}

// Truncation must not leave a trailing separator, which would render as a name
// with a dangling space.
func TestSanitiseDoesNotEndOnASeparator(t *testing.T) {
	input := strings.Repeat("a", maxDisplayNameLength) + "   tail"

	got := sanitise(input)

	if strings.HasSuffix(got, " ") {
		t.Fatalf("sanitise left a trailing space: %q", got)
	}
	if utf8.RuneCountInString(got) > maxDisplayNameLength {
		t.Fatalf("sanitise exceeded the limit: %d runes", utf8.RuneCountInString(got))
	}
}
