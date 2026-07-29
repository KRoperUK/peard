package moments

import "testing"

// Humanise has to agree with PeardCore's MomentSlug.humanised: both describe the
// same slug, and the moment breakdown shows the server's answer next to labels the
// client produced itself.
//
// It is reachable in normal use. Removing a custom moment deliberately leaves past
// posts with their kind so past tallies are unaffected, which means a slug outlives
// its moment_kinds row — and the breakdown then has only the slug to go on.
func TestHumanise(t *testing.T) {
	cases := map[string]string{
		"beer":            "Beer",
		"dog_walk":        "Dog walk",
		"thinking_of_you": "Thinking of you",
		// Only the first word is capitalised, matching the client: the rest are
		// left as typed, so "Dog Walk" is not forced on somebody who wrote
		// lower case.
		"gym_Session": "Gym Session",
		// A slug should never have a leading, trailing or doubled separator, but
		// the label must not gain a stray space if one does.
		"_loo":            "Loo",
		"loo_":            "Loo",
		"dog__walk":       "Dog walk",
		"":                "",
		"ok":              "Ok",
		"Wine":            "Wine",
		"three_word_slug": "Three word slug",
	}

	for slug, want := range cases {
		if got := Humanise(slug); got != want {
			t.Errorf("Humanise(%q) = %q, want %q", slug, got, want)
		}
	}
}

// A built-in resolves without touching the database, and its label is the curated
// one rather than a humanised slug.
func TestBuiltinLabelsWin(t *testing.T) {
	for slug, want := range map[string]string{"beer": "Beer", "loo": "Loo", "coffee": "Coffee"} {
		d, ok := Builtin(slug)
		if !ok {
			t.Fatalf("Builtin(%q) not found", slug)
		}
		if d.Label != want {
			t.Errorf("Builtin(%q).Label = %q, want %q", slug, d.Label, want)
		}
		if d.Emoji == "" || d.Emoji == FallbackEmoji {
			t.Errorf("Builtin(%q).Emoji = %q, want a specific emoji", slug, d.Emoji)
		}
	}
}
