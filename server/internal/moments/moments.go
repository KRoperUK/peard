// Package moments resolves a moment kind (a `posts.event_kind` slug) to the
// emoji and label used to describe it.
//
// Two sources, in precedence order:
//
//  1. the built-in kinds, which every connection has without any setup;
//  2. the connection's own `moment_kinds` rows, which is where a custom moment
//     invented on one device becomes legible to everybody else.
//
// Anything still unresolved falls back to the pear and a humanised slug, so a
// kind written by a newer client (or one whose `moment_kinds` row has since been
// removed) is never rendered blank or as a raw slug.
package moments

import (
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// Descriptor is everything needed to draw a moment.
type Descriptor struct {
	Slug  string `json:"kind"`
	Emoji string `json:"emoji"`
	Label string `json:"label"`
}

// FallbackEmoji is used for a kind with no descriptor anywhere.
const FallbackEmoji = "🍐"

// builtin mirrors PeardCore's MomentCatalogue.builtin. Keep the two in step:
// the client draws from its own copy, and this one is what the widget feed and
// the push copy use.
var builtin = map[string]Descriptor{
	"beer":   {Slug: "beer", Emoji: "🍺", Label: "Beer"},
	"loo":    {Slug: "loo", Emoji: "💩", Label: "Loo"},
	"coffee": {Slug: "coffee", Emoji: "☕", Label: "Coffee"},
}

// Builtin returns the descriptor for a built-in kind.
func Builtin(slug string) (Descriptor, bool) {
	d, ok := builtin[slug]
	return d, ok
}

// Resolve looks a single kind up for one connection.
func Resolve(app core.App, pairID, slug string) Descriptor {
	slug = strings.TrimSpace(slug)
	if slug == "" {
		return Descriptor{Slug: slug, Emoji: FallbackEmoji, Label: ""}
	}
	if d, ok := builtin[slug]; ok {
		return d
	}
	if pairID != "" {
		rec, err := app.FindFirstRecordByFilter("moment_kinds",
			"pair = {:pair} && slug = {:slug}",
			dbx.Params{"pair": pairID, "slug": slug})
		if err == nil && rec != nil {
			return Descriptor{
				Slug:  slug,
				Emoji: firstNonEmpty(rec.GetString("emoji"), FallbackEmoji),
				Label: firstNonEmpty(rec.GetString("label"), Humanise(slug)),
			}
		}
	}
	return Descriptor{Slug: slug, Emoji: FallbackEmoji, Label: Humanise(slug)}
}

// Humanise turns a slug into something printable: `dog_walk` -> `Dog walk`.
//
// Mirrors PeardCore's `MomentSlug.humanised`. It matters because a slug can
// outlive its `moment_kinds` row: removing a custom moment deliberately leaves
// past posts with their kind, so past tallies are unaffected — and without this
// the moment breakdown then lists `dog_walk` rather than "Dog walk".
//
// The client cannot patch this over: it only humanises when the label is missing
// entirely, and the fallback here always sends one.
func Humanise(slug string) string {
	words := strings.Split(strings.TrimSpace(slug), "_")
	var parts []string
	for _, word := range words {
		if word != "" {
			parts = append(parts, word)
		}
	}
	if len(parts) == 0 {
		return slug
	}
	parts[0] = strings.ToUpper(parts[0][:1]) + parts[0][1:]
	return strings.Join(parts, " ")
}

// ResolveAll looks up many kinds with a single query for the custom ones, so a
// tally list does not cost one round trip per kind.
func ResolveAll(app core.App, pairID string, slugs []string) map[string]Descriptor {
	out := make(map[string]Descriptor, len(slugs))
	var custom []string
	for _, slug := range slugs {
		slug = strings.TrimSpace(slug)
		if slug == "" {
			continue
		}
		if _, done := out[slug]; done {
			continue
		}
		if d, ok := builtin[slug]; ok {
			out[slug] = d
			continue
		}
		custom = append(custom, slug)
		// Provisional, replaced below if the connection has a row for it.
		out[slug] = Descriptor{Slug: slug, Emoji: FallbackEmoji, Label: Humanise(slug)}
	}
	if pairID == "" || len(custom) == 0 {
		return out
	}

	records, err := app.FindRecordsByFilter("moment_kinds",
		"pair = {:pair}", "", 200, 0, dbx.Params{"pair": pairID})
	if err != nil {
		return out
	}
	for _, rec := range records {
		slug := rec.GetString("slug")
		if _, wanted := out[slug]; !wanted {
			continue
		}
		out[slug] = Descriptor{
			Slug:  slug,
			Emoji: firstNonEmpty(rec.GetString("emoji"), FallbackEmoji),
			Label: firstNonEmpty(rec.GetString("label"), Humanise(slug)),
		}
	}
	return out
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
