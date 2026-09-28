// Package site serves the public marketing pages at the root of the domain:
// a hero and feature outline for anyone who lands on peard.kroper.uk with
// the app not installed yet, pointing them at the TestFlight build, plus the
// privacy policy and support page those app-store listings link to.
package site

import (
	_ "embed"
	"net/http"
	"regexp"
	"strings"

	"github.com/pocketbase/pocketbase/core"
)

const (
	testFlightURL = "https://testflight.apple.com/join/WdB7W3M1"
	contactEmail  = "kieran@kroper.uk"
	// Team id and bundle id, as Apple wants them for an associated domain.
	// Hard-coded rather than configured: it identifies this one app, and a
	// wrong value here fails silently — iOS just stops opening the links.
	appID = "72Q6R744M4.com.peard.app"
)

// Register binds the public site routes.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		// The site's routes share a group so that pageHeaders reaches them and
		// nothing else: PocketBase's /api/ and the /_/ superuser UI are
		// registered outside it, and the UI in particular needs the scripts the
		// policy below forbids.
		pages := se.Router.Group("")
		pages.BindFunc(pageHeaders)

		// "/{$}" is the root and nothing else. A bare "/" is a prefix match in
		// net/http, so the home page used to answer every unknown path with a
		// 200, which search engines read as a soft 404. "/" is kept, but only
		// to say so properly.
		pages.GET("/{$}", homeHandler)
		pages.GET("/", notFoundHandler)
		pages.GET("/privacy", privacyHandler)
		pages.GET("/support", supportHandler)
		pages.GET("/c/{code}", inviteHandler)
		pages.GET("/.well-known/apple-app-site-association", associationHandler)
		pages.GET("/apple-touch-icon.png", imageHandler(appleTouchIcon))
		pages.GET("/og.png", imageHandler(previewImage))
		return se.Next()
	})
}

// contentSecurityPolicy allows exactly what the pages use: the inline <style>
// block and the data: URL favicon. There are no scripts, fonts, frames or
// forms, so everything else is refused, and nobody may frame the pages.
const contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; " +
	"base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

// pageHeaders sets the security and caching headers for the site's pages.
//
// Invite pages are treated differently from the rest. The code in the URL is
// the invite itself, so it must not leave in a Referer when somebody taps
// through to TestFlight, and a shared or proxy cache must not keep a copy of
// it. Everything else is the same for every visitor and can be cached briefly.
//
// HSTS is only sent on a request that arrived over HTTPS, directly or through
// the TLS-terminating proxy or Cloudflare tunnel the deploy puts in front.
// Browsers ignore it over plain HTTP anyway, and a self-hosted server on plain
// HTTP shouldn't claim otherwise. Once a browser has it, the domain has to stay
// on HTTPS, which universal links already require. No includeSubDomains: the
// other hosts under the parent domain aren't this server's to promise for.
func pageHeaders(e *core.RequestEvent) error {
	path := e.Request.URL.Path
	// An unknown /api/ path reaches the catch-all and gets PocketBase's JSON
	// error, which should look like every other API response.
	if strings.HasPrefix(path, "/api/") {
		return e.Next()
	}

	h := e.Response.Header()
	h.Set("Content-Security-Policy", contentSecurityPolicy)
	h.Set("X-Content-Type-Options", "nosniff")
	// PocketBase sets SAMEORIGIN for everything. frame-ancestors supersedes it
	// in current browsers; this keeps older ones in agreement.
	h.Set("X-Frame-Options", "DENY")
	if strings.HasPrefix(path, "/c/") {
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
	} else {
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Cache-Control", "public, max-age=300")
	}
	if e.Request.TLS != nil || e.Request.Header.Get("X-Forwarded-Proto") == "https" {
		h.Set("Strict-Transport-Security", "max-age=31536000")
	}
	return e.Next()
}

// associationHandler serves the file iOS fetches to decide whether this domain
// may open the app.
//
// Served as application/json with no file extension, which is what Apple
// requires, and it must be reachable over https with no redirect — a redirect
// is the usual reason universal links quietly stop working.
//
// The only path claimed is /c/*. Claiming the whole domain would take /privacy
// with it, and a privacy policy that opens the app instead of a web page is
// both wrong and, for an app-store reviewer, unreadable.
func associationHandler(e *core.RequestEvent) error {
	e.Response.Header().Set("Content-Type", "application/json")
	e.Response.Header().Set("Cache-Control", "public, max-age=3600")
	return e.String(http.StatusOK, `{
  "applinks": {
    "details": [
      {
        "appIDs": ["`+appID+`"],
        "components": [
          { "/": "/c/*", "comment": "Invite links open the app" }
        ]
      }
    ]
  }
}`)
}

// inviteHandler is what an invite link resolves to for somebody who cannot open
// it in the app.
//
// With the app installed iOS never asks for this page — it hands the URL
// straight to Pear'd. So everything below is written for the other case: the
// person has been sent a link by a friend, has no app, and needs to know what
// this is and what to do next. The code is repeated in full because the
// TestFlight round trip loses the link, and typing it in afterwards is the only
// way back.
func inviteHandler(e *core.RequestEvent) error {
	code := strings.ToUpper(strings.TrimSpace(e.Request.PathValue("code")))
	// Codes are short and alphanumeric. Anything else is somebody poking at the
	// URL, and reflecting it into the page would be an invitation of a
	// different kind.
	if !inviteCodePattern.MatchString(code) {
		return e.HTML(http.StatusNotFound, page(e, pageMeta{
			title:       "Invite not found — Pear'd",
			description: "That invite link doesn't look right.",
		}, invitePage("", false)))
	}
	return e.HTML(http.StatusOK, page(e, pageMeta{
		title:       "Join on Pear'd 🍐",
		description: "Somebody wants to share moments with you on Pear'd.",
		path:        "/c/" + code,
		// The preview in the message thread is the first thing the invited
		// person sees, before they've tapped anything, so it says what the
		// link is rather than naming the app.
		previewTitle: "You've been invited to Pear'd",
	}, invitePage(code, true)))
}

var inviteCodePattern = regexp.MustCompile(`^[A-Z0-9]{4,12}$`)

func homeHandler(e *core.RequestEvent) error {
	return e.HTML(http.StatusOK, page(e, pageMeta{
		title:       "Pear'd 🍐",
		description: "Moments and tallies shared with your favourite people.",
		path:        "/",
	}, homeBody))
}

// notFoundHandler catches every GET that no other route claims.
//
// PocketBase's own routes are more specific patterns and still win, but an
// unknown /api/ path would land here too. API clients expect PocketBase's JSON
// error rather than a web page, so those get it.
func notFoundHandler(e *core.RequestEvent) error {
	if strings.HasPrefix(e.Request.URL.Path, "/api/") {
		return e.NotFoundError("", nil)
	}
	return e.HTML(http.StatusNotFound, page(e, pageMeta{
		title:       "Page not found — Pear'd",
		description: "There's nothing at this address.",
	}, notFoundBody))
}

func privacyHandler(e *core.RequestEvent) error {
	return e.HTML(http.StatusOK, page(e, pageMeta{
		title:       "Privacy Policy — Pear'd",
		description: "How Pear'd collects, uses and protects your data.",
		path:        "/privacy",
	}, privacyBody))
}

// supportHandler serves the page App Store Connect's Support URL points at.
//
// There is no /terms page to go with it: nothing in the app or its listing
// needs one yet, and Apple's standard licence agreement applies until it does.
func supportHandler(e *core.RequestEvent) error {
	return e.HTML(http.StatusOK, page(e, pageMeta{
		title:       "Support — Pear'd",
		description: "Get help with Pear'd: contact, common questions, deleting your account and beta feedback.",
		path:        "/support",
	}, supportBody))
}

// repoURL is where the footer sends anybody curious how it works. The repo is
// public, and the privacy policy's promises are easier to believe when the code
// that keeps them is a click away.
const repoURL = "https://github.com/KRoperUK/peard"

// The two images the site serves, both made from the app icon by
// scripts/site-images. They're embedded so the binary stays the whole deploy.
var (
	//go:embed static/apple-touch-icon.png
	appleTouchIcon []byte
	//go:embed static/og.png
	previewImage []byte
)

// imageHandler serves one of the embedded images. They change only when the app
// icon does, so they're cached for a month: long enough that a preview never
// waits on them, short enough that a new icon shows up without renaming files.
func imageHandler(png []byte) func(*core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		e.Response.Header().Set("Cache-Control", "public, max-age=2592000")
		return e.Blob(http.StatusOK, "image/png", png)
	}
}

// pageMeta is what a page says about itself, to the browser tab and to the
// link previews iMessage and the rest build from the Open Graph tags.
type pageMeta struct {
	title       string
	description string
	// path is the page's canonical path. Empty on an error page, which isn't
	// an address anybody should be sent to, so it gets no canonical link.
	path string
	// previewTitle, when set, is used in link previews instead of title.
	previewTitle string
}

// publicURL is the site's own address, from PEARD_APP_URL (see main.go), for
// the absolute URLs link previews need. Not the request's Host header: that is
// whatever the client sent, and the pages are publicly cacheable, so a forged
// one could put somebody else's domain into a cached copy.
func publicURL(e *core.RequestEvent) string {
	return strings.TrimRight(e.App.Settings().Meta.AppURL, "/")
}

// attr escapes a value for a double-quoted HTML attribute. The values are
// constants and validated codes today, but the base URL comes from config.
var attr = strings.NewReplacer(`&`, "&amp;", `"`, "&quot;", `<`, "&lt;", `>`, "&gt;").Replace

// previewTags are the head tags for search engines, link previews and the Home
// Screen. There's no apple-itunes-app Smart App Banner yet: it needs the app on
// the App Store, and while it's TestFlight only the banner would lead nowhere.
func previewTags(e *core.RequestEvent, m pageMeta) string {
	base := publicURL(e)
	title := m.previewTitle
	if title == "" {
		title = m.title
	}
	tags := `<meta property="og:site_name" content="Pear'd">
<meta property="og:type" content="website">
<meta property="og:title" content="` + attr(title) + `">
<meta property="og:description" content="` + attr(m.description) + `">
<meta property="og:image" content="` + attr(base) + `/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="The Pear'd app icon, two pears, beside the name Pear'd">
<meta name="twitter:card" content="summary_large_image">
`
	if m.path != "" {
		url := attr(base + m.path)
		tags += `<meta property="og:url" content="` + url + `">
<link rel="canonical" href="` + url + `">
`
	}
	return tags + `<meta name="theme-color" content="#FBF7EC" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#1C1810" media="(prefers-color-scheme: dark)">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
`
}

// page wraps a page's body with the shared document head, styling and footer.
//
// The body goes inside <main> and the footer stays outside it, so a screen
// reader can jump straight to the content or the links without walking a page
// of anonymous divs.
func page(e *core.RequestEvent, m pageMeta, body string) string {
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>` + m.title + `</title>
<meta name="description" content="` + m.description + `">
` + previewTags(e, m) + `<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 16 16%22><text y=%2214%22 font-size=%2214%22>🍐</text></svg>">
<style>` + sharedCSS + `</style>
</head>
<body>
<main>
` + body + `
</main>
  <footer class="site-footer">
    <div class="footer-rule" aria-hidden="true"><span>🍐</span></div>
    <nav class="footer-links" aria-label="Footer">
      <a href="/">Pear'd</a>
      <a href="/privacy">Privacy Policy</a>
      <a href="/support">Support</a>
      <a href="` + repoURL + `" rel="noopener">
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" focusable="false"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
        Source on GitHub
      </a>
    </nav>
    <p class="footer-note">Open source, made for pubs, trains and loo queues.</p>
  </footer>
</body>
</html>
`
}

const sharedCSS = `
  :root {
    --background: #FBF7EC;
    --surface: #FFFFFF;
    --text-primary: #3B2E1A;
    --text-secondary: #7A6A53;
    /* The app's olive (#6B8E23) is too light to carry text here: 3.5:1 as a
       link on the page background and 3.8:1 under the white button label,
       against WCAG AA's 4.5:1. This darker shade keeps the olive and clears
       it — 5.4:1 on the background, 5.8:1 on white both ways. */
    --accent: #4F6F1A;
    --on-accent: #FFFFFF;
    --divider: #E8DFCC;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --background: #1C1810;
      --surface: #262016;
      --text-primary: #F2E9D8;
      --text-secondary: #C3B49B;
      --accent: #9BBF4F;
      /* The dark-mode accent is light, so white on it was 2.1:1. The page's
         own dark brown reads 8.4:1 on it. */
      --on-accent: #1C1810;
      --divider: #3A3226;
    }
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; }
  body {
    background: var(--background);
    color: var(--text-primary);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  a { color: var(--accent); }
  .hero {
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    padding: 64px 32px 48px;
  }
  .pear { font-size: 72px; line-height: 1; }
  h1 { font-size: 40px; margin: 16px 0 8px; }
  .tagline {
    font-size: 17px;
    color: var(--text-secondary);
    max-width: 420px;
    margin: 0 0 32px;
    line-height: 1.4;
  }
  .cta {
    display: inline-block;
    padding: 14px 28px;
    border-radius: 12px;
    background: var(--accent);
    color: var(--on-accent);
    font-size: 17px;
    font-weight: 600;
    text-decoration: none;
  }
  .cta:active { opacity: 0.85; }
  .features {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 20px;
    max-width: 900px;
    margin: 0 auto;
    padding: 0 32px 64px;
  }
  .feature {
    background: var(--surface);
    border: 1px solid var(--divider);
    border-radius: 16px;
    padding: 24px;
    text-align: left;
  }
  .feature .emoji { font-size: 28px; }
  .feature h2 {
    font-size: 18px;
    margin: 12px 0 6px;
  }
  .feature p {
    font-size: 15px;
    color: var(--text-secondary);
    margin: 0;
    line-height: 1.5;
  }
  .site-footer {
    text-align: center;
    padding: 24px 24px 40px;
    font-size: 14px;
    color: var(--text-secondary);
  }
  .footer-rule {
    display: flex;
    align-items: center;
    gap: 14px;
    max-width: 420px;
    margin: 0 auto 20px;
    font-size: 18px;
  }
  .footer-rule::before, .footer-rule::after {
    content: "";
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, transparent, var(--divider));
  }
  .footer-rule::after { background: linear-gradient(90deg, var(--divider), transparent); }
  .footer-rule span { display: inline-block; transition: transform 0.4s ease; }
  .site-footer:hover .footer-rule span { transform: rotate(-14deg) scale(1.15); }
  .footer-links {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 10px;
  }
  .footer-links a {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 8px 14px;
    border-radius: 999px;
    border: 1px solid var(--divider);
    background: var(--surface);
    color: var(--text-primary);
    font-weight: 500;
    text-decoration: none;
    transition: transform 0.15s ease, border-color 0.15s ease, color 0.15s ease;
  }
  .footer-links a:hover, .footer-links a:focus-visible {
    border-color: var(--accent);
    color: var(--accent);
    transform: translateY(-1px);
  }
  .footer-links a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .footer-note { margin: 18px 0 0; font-size: 13px; }
  @media (prefers-reduced-motion: reduce) {
    .footer-rule span, .footer-links a { transition: none; }
    .site-footer:hover .footer-rule span, .footer-links a:hover { transform: none; }
  }
  .doc {
    max-width: 640px;
    margin: 0 auto;
    padding: 56px 24px 24px;
    line-height: 1.6;
  }
  .doc h1 { font-size: 32px; margin-bottom: 4px; }
  .doc .updated {
    color: var(--text-secondary);
    font-size: 14px;
    margin-bottom: 32px;
  }
  .doc h2 { font-size: 20px; margin-top: 36px; }
  .doc p, .doc li { color: var(--text-secondary); font-size: 16px; }
  .notice {
    background: var(--surface);
    border: 1px solid var(--divider);
    border-radius: 16px;
    padding: 20px 24px;
    margin: 0 0 28px;
    max-width: 460px;
    text-align: left;
  }
  .notice ol { margin: 10px 0 0; padding-left: 20px; }
  .notice li {
    color: var(--text-secondary);
    font-size: 15px;
    line-height: 1.5;
    margin-bottom: 6px;
  }
  .keep-code {
    color: var(--text-secondary);
    font-size: 15px;
    margin: 16px 0 8px;
  }
  .code {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 28px;
    font-weight: 700;
    letter-spacing: 6px;
    text-align: center;
    padding: 12px;
    border-radius: 12px;
    background: var(--background);
    border: 1px solid var(--divider);
    /* Selectable on purpose: copying beats retyping, and the whole point of
       this page is that the code has to survive a trip to the App Store. */
    user-select: all;
  }
  .tagline.small { font-size: 15px; margin-top: 24px; }
`

const homeBody = `
  <header class="hero">
    <div class="pear" aria-hidden="true">🍐</div>
    <h1>Pear'd</h1>
    <p class="tagline">Moments and tallies shared with your favourite people — like a locket for photos, a counter for the beers, and a nod for the loo.</p>
    <a class="cta" href="` + testFlightURL + `">Try it on TestFlight</a>
  </header>
  <div class="features">
    <div class="feature">
      <div class="emoji" aria-hidden="true">🍺</div>
      <h2>Moments</h2>
      <p>Beer, loo and coffee are built in, or invent your own. One tap sends it — a three-second window to add a note before it goes.</p>
    </div>
    <div class="feature">
      <div class="emoji" aria-hidden="true">📊</div>
      <h2>Tallies</h2>
      <p>Every moment counted, with a per-moment breakdown for the day, week or month.</p>
    </div>
    <div class="feature">
      <div class="emoji" aria-hidden="true">👥</div>
      <h2>Pairs &amp; groups</h2>
      <p>Be in up to 20 connections at once, each holding up to 12 people, and switch between them from a rail of faces.</p>
    </div>
    <div class="feature">
      <div class="emoji" aria-hidden="true">🔒</div>
      <h2>Private by design</h2>
      <p>You can only see somebody's name or photo if you share a connection with them — enforced by the server, not just the app.</p>
    </div>
  </div>
`

const notFoundBody = `
  <div class="hero">
    <div class="pear" aria-hidden="true">🍐</div>
    <h1>Nothing here</h1>
    <p class="tagline">This page doesn't exist, or it has moved. If somebody sent you an invite, check the link — they look like <code>peard.kroper.uk/c/ABC123</code>.</p>
    <a class="cta" href="/">Go to Pear'd</a>
  </div>
`

// invitePage is the landing page for an invite link opened outside the app.
//
// It leads with the banner rather than the code, because the order matters:
// somebody who taps "Try it on TestFlight" first and reads afterwards has lost
// the link, and the code is the only way back. Saying "you'll need the code
// again" *before* the button is what makes that recoverable.
func invitePage(code string, found bool) string {
	if !found {
		return `
  <div class="hero">
    <div class="pear" aria-hidden="true">🍐</div>
    <h1>That link didn't work</h1>
    <p class="tagline">Invite links look like <code>peard.kroper.uk/c/ABC123</code>. Ask whoever sent it to share it again — they expire after 24 hours.</p>
    <a class="cta" href="/">About Pear'd</a>
  </div>
`
	}
	return `
  <div class="hero">
    <div class="pear" aria-hidden="true">🍐</div>
    <h1>You've been invited</h1>
    <p class="tagline">Somebody wants to share moments with you on Pear'd — the beers, the coffees, the dog walks, and the photos in between.</p>

    <div class="notice">
      <strong>Pear'd is in beta, so there are two steps.</strong>
      <ol>
        <li>Install <a href="https://apps.apple.com/app/testflight/id899247664">TestFlight</a> from the App Store, if you haven't got it.</li>
        <li>Join the Pear'd beta with the button below, then open Pear'd and enter your code.</li>
      </ol>
      <p class="keep-code">Keep this code — you'll need to type it in after installing:</p>
      <div class="code" aria-label="Invite code ` + strings.Join(strings.Split(code, ""), " ") + `">` + code + `</div>
    </div>

    <a class="cta" href="` + testFlightURL + `">Join the Pear'd beta</a>
    <p class="tagline small">Already have Pear'd? Open the app and enter <strong>` + code + `</strong> — or tap this link again from your phone.</p>
  </div>
`
}

const privacyBody = `
  <div class="doc">
    <header>
      <h1>Privacy Policy</h1>
      <div class="updated">Last updated 28 September 2026</div>
    </header>

    <p>Pear'd ("we", "us") is a small, independently-run app for sharing moments and tallies with people you choose to connect with. This page explains what we collect, why, and how to get it deleted.</p>

    <h2>Your agreement comes first</h2>
    <p>The app asks you to agree to this policy before it sends anything anywhere — before you sign in, not alongside it. Signing in is itself the first thing that leaves your device, so the question has to come before the button. If we change this policy in a way you should see, the app asks again on the next launch rather than assuming your old answer still stands.</p>

    <h2>What we collect</h2>
    <ul>
      <li><strong>Account info</strong> — an identifier and email address from Sign in with Apple, Google, or your own email and password.</li>
      <li><strong>Sign in with Apple token</strong> — if you sign in with Apple, a token Apple issues to us, kept only on our server and used for one thing: telling Apple to revoke Pear'd's access when you delete your account.</li>
      <li><strong>Profile</strong> — the display name and photo you optionally set, shown to people you share a connection with.</li>
      <li><strong>Moments</strong> — the events you log, including any note or photo you attach, and the reactions, custom moment kinds, group names and group photos you add.</li>
      <li><strong>Read state</strong> — when you last opened each connection, so the app can show what's new since.</li>
      <li><strong>Push tokens</strong> — a device token used only to deliver notifications from your connections, and, while a Live Activity is running, a token that updates it on your Lock Screen.</li>
      <li><strong>Widget tokens</strong> — a random key the home screen widget uses to fetch your latest moments without your password. You can see them in your data export; they are cancelled if you withdraw Pear'd's access in your Apple Account settings, and deleted with your account.</li>
      <li><strong>Phone number and contact email (optional)</strong> — only ever asked for if you turn on "let people find me" in Settings; nothing else asks for them.</li>
      <li><strong>Server logs</strong> — our server records each request it receives: the time, the address asked for, the result, your IP address and your device's user agent (which names the app and system version), and for some events your account id. They're used only to keep the service running and to investigate faults and abuse, and they're deleted automatically after 5 days.</li>
    </ul>

    <h2>Who can see it</h2>
    <p>Only people you share a connection with — a pair or group you have joined — can see your name, photo or moments. This is enforced by rules on the server, not only by the app.</p>

    <h2>Finding friends from your contacts</h2>
    <p>Pear'd can check whether people in your contacts are already on Pear'd. Before anything leaves your device, each contact's email and phone number is turned into a one-way hash (SHA-256) — the app never sends your contacts' actual details anywhere, including for people who aren't on Pear'd at all. The server compares those hashes against the ones it holds for accounts that turned on "let people find me," tells you which of them matched, and doesn't keep the hashes you sent.</p>
    <p>Searching your own contacts needs no opt-in from you. Being found by someone else's search does — it's off by default, and turning it on is what lets your email (and phone number, if you add one) be matched at all.</p>
    <p>The hashes we store for discoverable accounts are keyed with a secret held only by our server, outside its database, so a stolen copy of the database can't be turned back into email addresses or phone numbers. That protects against a leak, not against us: the hashes your app sends arrive at our server unkeyed (encrypted in transit), and a plain hash of a phone number can in principle be reversed by trying every number, so whoever runs the server could work them out. Preventing that too would take a far more complex cryptographic protocol, which Pear'd doesn't use. It's meaningfully better than sending contacts in the clear, not a promise of anonymity — a trade-off we'd rather state plainly than gloss over.</p>

    <h2>Who we share it with</h2>
    <p>We don't sell or share your data with advertisers, and we don't run analytics or tracking in the app. Data passes through:</p>
    <ul>
      <li>Apple or Google, to sign you in.</li>
      <li>Apple's Push Notification service, to deliver alerts to your device.</li>
      <li>Apple's Live Activity push service, to update a running Live Activity.</li>
      <li>The server we operate, where everything above is stored.</li>
    </ul>

    <h2>TestFlight beta feedback</h2>
    <p>If you test a beta through TestFlight and send feedback, Apple passes it to us: your comment, any screenshots, and details such as your device model, system version, locale, time zone, connection type and battery level. We send each piece of feedback to OpenRouter, an AI service, which routes it to a language model that sorts it into a bug report or feature request. The comment and the device details are then posted as an issue on our GitHub repository, which is public — the issue never names you or includes your email address, and screenshots stay in App Store Connect rather than being published. This only applies to beta feedback you choose to send; the App Store version of the app sends nothing of the kind.</p>

    <h2>Retention</h2>
    <p>By default, moments you post stay part of a connection's shared history even if you later leave it — leaving removes your membership, not the record of what already happened, which was somebody else's record of it too. When you leave, the app offers to delete your own moments from that connection instead; choosing that removes them for everyone in it. Your account data is kept for as long as your account exists.</p>

    <h2>Your rights</h2>
    <p>You can sign out at any time from the app, and download a copy of everything we hold about you any time from Settings → Export your data: your profile, connections, invites, moments, reactions, custom moment kinds, devices, widget tokens and Live Activities. Tokens appear masked or are left out, because they are keys rather than your content. Photo links in the export stop working about 30 minutes after it's made, so save the photos soon after exporting, or export again.</p>
    <p>You can delete your account from Settings → Delete account. It happens immediately and takes your profile, your photo, your moments across every connection, your reactions, your push and widget tokens and your Live Activities with it — you don't have to ask us, and there's nothing to wait for. If you signed in with Apple, we also tell Apple to revoke Pear'd's access, as if you had removed it under Settings → Apple Account → Sign in with Apple. Any connection you leave behind that still has other people in it keeps its shared history minus your moments; one that had only you is deleted outright.</p>
    <p>If you'd rather we did it, or you want to ask what we hold, email <a href="mailto:` + contactEmail + `">` + contactEmail + `</a> — we'll action requests within 30 days.</p>

    <h2>Children</h2>
    <p>Pear'd is not directed at children under 13, and we don't knowingly collect data from them.</p>

    <h2>Changes</h2>
    <p>If this policy changes, we'll update the date at the top of this page. When a change is one you should see, the app also asks you to agree to the new version on its next launch, before it sends anything else.</p>

    <h2>Contact</h2>
    <p><a href="mailto:` + contactEmail + `">` + contactEmail + `</a></p>
  </div>
`

// supportBody describes the app as it is, so each answer names the control it
// means by the words on screen. Change the app's wording and this goes stale.
const supportBody = `
  <div class="doc">
    <header>
      <h1>Support</h1>
      <div class="updated">Help with Pear'd</div>
    </header>

    <h2>Contact</h2>
    <p>Email <a href="mailto:` + contactEmail + `">` + contactEmail + `</a>. Pear'd is run by one person, so replies can take a few days.</p>
    <p>If something's broken, include your diagnostics: in the app, open <strong>Settings</strong>, go down to <strong>About</strong> and tap <strong>Copy diagnostics</strong>, then paste them into your email. They say which build of the app and the server you're on, and nothing about you.</p>

    <h2>Common questions</h2>

    <h3>My invite link or code doesn't work</h3>
    <p>Invite codes expire 24 hours after they're made, and each one can only be used once. Ask whoever invited you to make a new one. Codes are letters and numbers only, and upper or lower case both work.</p>

    <h3>How do I stop notifications from one connection?</h3>
    <p>On <strong>Home</strong>, pick the connection from the row of faces at the top. Then open <strong>Settings</strong> and turn on <strong>Mute this connection</strong>. Moments still arrive and still show in the widget; they just stop making a noise. Muting only affects you.</p>

    <h3>How do I add the widget?</h3>
    <p>Touch and hold an empty part of your Home Screen, add a widget and choose Pear'd. It comes in small and medium sizes, and for the Lock Screen. On the Home Screen it shows the latest moment and today's tallies, and its buttons log a moment without opening the app. To choose which connection it follows, touch and hold it and tap <strong>Edit Widget</strong>. Left on <strong>Automatic</strong>, it follows whichever connection is liveliest.</p>
    <p>On iOS 18 and later there are also Control Centre controls to log a beer, coffee or loo.</p>

    <h3>Can I use Siri?</h3>
    <p>Yes. Say "Log a beer in Pear'd" (or coffee, or loo) to log one straight away, or "Log a moment in Pear'd" to choose any moment, including ones your connection made up. Both are also actions in the Shortcuts app. Without a connection chosen, they go to your liveliest one.</p>

    <h2>Deleting your account</h2>
    <p>In the app, open <strong>Settings</strong>, tap <strong>Delete account</strong>, then <strong>Delete my account</strong>. It happens straight away and can't be undone: your profile, photo, moments, reactions and push registration are erased, as the <a href="/privacy">privacy policy</a> describes. To keep a copy, tap <strong>Export your data</strong> on the same screen first.</p>
    <p>The Settings tab is only there once you're in a connection. If you aren't in one, or you'd rather we did it, email <a href="mailto:` + contactEmail + `">` + contactEmail + `</a> from the address you signed up with.</p>

    <h2>Beta feedback</h2>
    <p>Pear'd is in beta on TestFlight. To send feedback, take a screenshot in Pear'd and tap <strong>Share Beta Feedback</strong>, or open the TestFlight app, choose Pear'd and tap <strong>Send Beta Feedback</strong>. If the app crashes, TestFlight will offer to send a report.</p>
    <p>Feedback is used to track bugs, and what you write may be copied into an issue in Pear'd's <a href="` + repoURL + `">public source repository</a>. For anything private, email instead.</p>
  </div>
`
