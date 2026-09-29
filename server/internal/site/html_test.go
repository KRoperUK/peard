package site_test

import (
	"fmt"
	"io"
	"strings"
	"testing"

	"golang.org/x/net/html"
)

// The pages are hand-written HTML in Go string constants, so nothing but a
// browser's forgiveness stands between a typo and a broken page — and a browser
// forgives almost everything, which is exactly why a stray </div> or an image
// with no alt text goes unnoticed. The other tests here look for substrings;
// this one reads each page as a document.
//
// A structural check in `go test` rather than the W3C validator or axe: both of
// those need Java or a headless browser, which the server job does not have and
// should not grow for a handful of static pages, while this runs on every pull
// request in milliseconds with a tokenizer already in the module graph. What it
// cannot see — colour, focus order, anything that needs layout — is either
// checked elsewhere (TestColoursMeetWCAGContrast) or out of reach without a
// browser. See checkPage for the rules.
func TestPagesAreWellFormedAndAccessible(t *testing.T) {
	mux := newSiteMux(t)

	// Every page the site renders: the three marketing pages, the invite page
	// in each of its three states, and the not-found page. ABC123 is seeded as a
	// live invite by newSiteApp; NEVER1 is not, so it is a dead one.
	for _, path := range []string{"/", "/privacy", "/support", "/c/ABC123", "/c/NEVER1", "/c/AB-12", "/nope"} {
		t.Run(path, func(t *testing.T) {
			for _, problem := range checkPage(get(t, mux, path).Body.String()) {
				t.Error(problem)
			}
		})
	}
}

// The checker has to be seen to fail, or a bug in it passes every page. One
// broken document per rule, each of which must be reported.
func TestPageCheckCatchesBrokenMarkup(t *testing.T) {
	const head = `<!doctype html><html lang="en"><head><title>t</title></head><body>`
	const tail = `</body></html>`
	cases := map[string]string{
		"missing doctype":      `<html lang="en"><head><title>t</title></head><body><main><h1>x</h1></main></body></html>`,
		"no lang":              `<!doctype html><html><head><title>t</title></head><body><main><h1>x</h1></main></body></html>`,
		"empty title":          `<!doctype html><html lang="en"><head><title> </title></head><body><main><h1>x</h1></main></body></html>`,
		"unclosed element":     head + `<main><h1>x</h1><div></main>` + tail,
		"stray end tag":        head + `<main><h1>x</h1></div></main>` + tail,
		"closed void element":  head + `<main><h1>x</h1><br></br></main>` + tail,
		"self-closed div":      head + `<main><h1>x</h1><div/></main>` + tail,
		"no main":              head + `<h1>x</h1>` + tail,
		"two mains":            head + `<main><h1>x</h1></main><main></main>` + tail,
		"img without alt":      head + `<main><h1>x</h1><img src="a.png"></main>` + tail,
		"link without text":    head + `<main><h1>x</h1><a href="/"><span aria-hidden="true">🍐</span></a></main>` + tail,
		"link without href":    head + `<main><h1>x</h1><a>home</a></main>` + tail,
		"first heading not h1": head + `<main><h2>x</h2></main>` + tail,
		"skipped heading":      head + `<main><h1>x</h1><h3>y</h3></main>` + tail,
		"two h1s":              head + `<main><h1>x</h1><h1>y</h1></main>` + tail,
		"duplicate id":         head + `<main><h1 id="a">x</h1><p id="a">y</p></main>` + tail,
	}
	for name, doc := range cases {
		if problems := checkPage(doc); len(problems) == 0 {
			t.Errorf("%s: not reported", name)
		}
	}

	good := head + `<main><h1>x</h1><h2 id="a">y</h2><img src="a.png" alt=""><a href="/" aria-label="Home"><svg aria-hidden="true"><path d="M0 0"/></svg></a></main>` + tail
	if problems := checkPage(good); len(problems) != 0 {
		t.Errorf("a valid page was rejected: %v", problems)
	}
}

// voidElements never have an end tag; everything else must be closed
// explicitly. HTML lets a </p> or </li> be implied, but these pages never rely
// on that, and holding them to it is what makes a genuinely missing tag visible.
var voidElements = map[string]bool{
	"area": true, "base": true, "br": true, "col": true, "embed": true, "hr": true, "img": true,
	"input": true, "link": true, "meta": true, "source": true, "track": true, "wbr": true,
}

// openElement is one entry on checkPage's stack of open elements.
type openElement struct {
	name string
	// Inside an aria-hidden subtree, which contributes nothing to an
	// accessible name.
	hidden bool
	// Inside <svg> or <math>, where XML's self-closing syntax is allowed.
	foreign bool
}

// openLink is the <a> being read, with whatever accessible name it has so far.
type openLink struct {
	depth int
	name  strings.Builder
}

// checkPage returns every problem found in doc, or nil for a clean page:
//
//   - a doctype, then well-formed markup: every element closed in order, void
//     elements never closed, no self-closing HTML elements (the tokenizer
//     drops a repeated attribute before it can be seen, as browsers do, so that
//     one is not checked)
//   - <html lang> set, a non-empty <title>
//   - exactly one <main>
//   - every <img> has alt (empty is allowed, for decoration)
//   - every <a> has an href and an accessible name: text outside aria-hidden,
//     aria-label, or an image's alt text
//   - one <h1>, it comes first, and no heading skips a level on the way down
//   - no id used twice
func checkPage(doc string) []string {
	var problems []string
	report := func(format string, args ...any) { problems = append(problems, fmt.Sprintf(format, args...)) }

	z := html.NewTokenizer(strings.NewReader(doc))
	var stack []openElement
	var link *openLink
	var headings []int
	ids := map[string]bool{}
	sawDoctype, sawElement := false, false
	mains, titles := 0, 0
	var title *strings.Builder

	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			if err := z.Err(); err != io.EOF {
				report("tokenizer: %v", err)
			}
			break
		}
		tok := z.Token()
		switch tt {
		case html.DoctypeToken:
			if sawElement {
				report("doctype after the first element")
			}
			if !strings.EqualFold(tok.Data, "html") {
				report("doctype %q, want html", tok.Data)
			}
			sawDoctype = true

		case html.StartTagToken, html.SelfClosingTagToken:
			if !sawElement && !sawDoctype {
				report("no <!doctype html> before <%s>", tok.Data)
			}
			sawElement = true
			parent := openElement{}
			if len(stack) > 0 {
				parent = stack[len(stack)-1]
			}
			el := openElement{
				name:    tok.Data,
				hidden:  parent.hidden || attr(tok, "aria-hidden") == "true",
				foreign: parent.foreign || tok.Data == "svg" || tok.Data == "math",
			}
			checkElement(tok, report, ids)

			switch tok.Data {
			case "main":
				mains++
			case "title":
				titles++
				title = &strings.Builder{}
			case "h1", "h2", "h3", "h4", "h5", "h6":
				headings = append(headings, int(tok.Data[1]-'0'))
			case "a":
				if link != nil {
					report("<a> nested inside another <a>")
				}
				link = &openLink{depth: len(stack)}
				if label := strings.TrimSpace(attr(tok, "aria-label")); label != "" {
					link.name.WriteString(label)
				}
			case "img":
				if link != nil && !el.hidden {
					link.name.WriteString(attr(tok, "alt"))
				}
			}

			if voidElements[tok.Data] {
				continue
			}
			if tt == html.SelfClosingTagToken {
				if !el.foreign {
					report("<%s/> is self-closed, which HTML ignores — it stays open", tok.Data)
				}
				continue
			}
			stack = append(stack, el)

		case html.EndTagToken:
			if voidElements[tok.Data] {
				report("</%s>: a void element has no end tag", tok.Data)
				continue
			}
			// Matched against the nearest open element of the same name, so one
			// missing end tag is reported once rather than as a mismatch at
			// every level above it.
			match := len(stack) - 1
			for match >= 0 && stack[match].name != tok.Data {
				match--
			}
			if match < 0 {
				report("</%s> closes nothing that is open", tok.Data)
				continue
			}
			for _, unclosed := range stack[match+1:] {
				report("<%s> is not closed before </%s>", unclosed.name, tok.Data)
			}
			stack = stack[:match]
			switch {
			case tok.Data == "a" && link != nil && link.depth == len(stack):
				if strings.TrimSpace(link.name.String()) == "" {
					report("a link with no accessible name")
				}
				link = nil
			case tok.Data == "title" && title != nil:
				if strings.TrimSpace(title.String()) == "" {
					report("<title> is empty")
				}
				title = nil
			}

		case html.TextToken:
			if title != nil {
				title.WriteString(tok.Data)
			}
			if link != nil && (len(stack) == 0 || !stack[len(stack)-1].hidden) {
				link.name.WriteString(tok.Data)
			}
		}
	}

	for i := len(stack) - 1; i >= 0; i-- {
		report("<%s> is never closed", stack[i].name)
	}
	if mains != 1 {
		report("%d <main> elements, want exactly one", mains)
	}
	if titles != 1 {
		report("%d <title> elements, want exactly one", titles)
	}
	problems = append(problems, checkHeadings(headings)...)
	return problems
}

// checkElement holds the per-element rules: ids, lang, alt and href.
func checkElement(tok html.Token, report func(string, ...any), ids map[string]bool) {
	seen := map[string]bool{}
	for _, a := range tok.Attr {
		seen[a.Key] = true
	}
	if id := attr(tok, "id"); id != "" {
		if ids[id] {
			report("id %q is used more than once", id)
		}
		ids[id] = true
	}
	switch tok.Data {
	case "html":
		if strings.TrimSpace(attr(tok, "lang")) == "" {
			report("<html> has no lang")
		}
	case "img":
		if !seen["alt"] {
			report("<img src=%q> has no alt", attr(tok, "src"))
		}
	case "a":
		if !seen["href"] {
			report("<a> has no href")
		}
	}
}

// checkHeadings wants one <h1>, first, and no level skipped going down: an h2
// can follow an h4, but an h4 cannot follow an h2, because a screen reader's
// outline would show a section with a missing parent.
func checkHeadings(levels []int) []string {
	var problems []string
	if len(levels) == 0 {
		return []string{"no headings"}
	}
	if levels[0] != 1 {
		problems = append(problems, fmt.Sprintf("the first heading is <h%d>, want <h1>", levels[0]))
	}
	h1s := 0
	for i, level := range levels {
		if level == 1 {
			h1s++
		}
		if i > 0 && level > levels[i-1]+1 {
			problems = append(problems, fmt.Sprintf("<h%d> follows <h%d>, skipping a level", level, levels[i-1]))
		}
	}
	if h1s != 1 {
		problems = append(problems, fmt.Sprintf("%d <h1> elements, want exactly one", h1s))
	}
	return problems
}

func attr(tok html.Token, key string) string {
	for _, a := range tok.Attr {
		if a.Key == key {
			return a.Val
		}
	}
	return ""
}
