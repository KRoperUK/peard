// Package site serves the public marketing pages at the root of the domain:
// a hero and feature outline for anyone who lands on peard.kroper.uk with
// the app not installed yet, pointing them at the TestFlight build, plus the
// privacy policy those app-store listings link to.
package site

import (
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
		se.Router.GET("/", homeHandler)
		se.Router.GET("/privacy", privacyHandler)
		se.Router.GET("/c/{code}", inviteHandler)
		se.Router.GET("/.well-known/apple-app-site-association", associationHandler)
		return se.Next()
	})
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
		return e.HTML(http.StatusNotFound, page(
			"Invite not found — Pear'd",
			"That invite link doesn't look right.",
			invitePage("", false),
		))
	}
	return e.HTML(http.StatusOK, page(
		"Join on Pear'd 🍐",
		"Somebody wants to share moments with you on Pear'd.",
		invitePage(code, true),
	))
}

var inviteCodePattern = regexp.MustCompile(`^[A-Z0-9]{4,12}$`)

func homeHandler(e *core.RequestEvent) error {
	return e.HTML(http.StatusOK, page(
		"Pear'd 🍐",
		"Moments and tallies shared with your favourite people.",
		homeBody,
	))
}

func privacyHandler(e *core.RequestEvent) error {
	return e.HTML(http.StatusOK, page(
		"Privacy Policy — Pear'd",
		"How Pear'd collects, uses and protects your data.",
		privacyBody,
	))
}

// page wraps a page's body with the shared document head, styling and footer.
func page(title, description, body string) string {
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>` + title + `</title>
<meta name="description" content="` + description + `">
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 16 16%22><text y=%2214%22 font-size=%2214%22>🍐</text></svg>">
<style>` + sharedCSS + `</style>
</head>
<body>
` + body + `
  <footer class="site-footer">
    <a href="/">Pear'd</a> · <a href="/privacy">Privacy Policy</a>
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
    --accent: #6B8E23;
    --divider: #E8DFCC;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --background: #1C1810;
      --surface: #262016;
      --text-primary: #F2E9D8;
      --text-secondary: #C3B49B;
      --accent: #9BBF4F;
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
    color: #fff;
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
    padding: 32px;
    font-size: 14px;
    color: var(--text-secondary);
  }
  .site-footer a { text-decoration: none; }
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
  <div class="hero">
    <div class="pear" aria-hidden="true">🍐</div>
    <h1>Pear'd</h1>
    <p class="tagline">Moments and tallies shared with your favourite people — like a locket for photos, a counter for the beers, and a nod for the loo.</p>
    <a class="cta" href="` + testFlightURL + `">Try it on TestFlight</a>
  </div>
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
    <h1>Privacy Policy</h1>
    <div class="updated">Last updated 31 July 2026</div>

    <p>Pear'd ("we", "us") is a small, independently-run app for sharing moments and tallies with people you choose to connect with. This page explains what we collect, why, and how to get it deleted.</p>

    <h2>Your agreement comes first</h2>
    <p>The app asks you to agree to this policy before it sends anything anywhere — before you sign in, not alongside it. Signing in is itself the first thing that leaves your device, so the question has to come before the button. If we change this policy in a way you should see, the app asks again on the next launch rather than assuming your old answer still stands.</p>

    <h2>What we collect</h2>
    <ul>
      <li><strong>Account info</strong> — an identifier and email address from Sign in with Apple, Google, or your own email and password.</li>
      <li><strong>Profile</strong> — the display name and photo you optionally set, shown to people you share a connection with.</li>
      <li><strong>Moments</strong> — the events you log, including any note or photo you attach.</li>
      <li><strong>Push token</strong> — a device token used only to deliver notifications from your connections.</li>
      <li><strong>Phone number (optional)</strong> — only ever asked for if you turn on "let people find me" in Settings; nothing else asks for one.</li>
    </ul>

    <h2>Who can see it</h2>
    <p>Only people you share a connection with — a pair or group you have joined — can see your name, photo or moments. This is enforced by rules on the server, not only by the app.</p>

    <h2>Finding friends from your contacts</h2>
    <p>Pear'd can check whether people in your contacts are already on Pear'd. Before anything leaves your device, each contact's email and phone number is turned into a one-way hash (SHA-256) — the app never sends your contacts' actual details anywhere, including for people who aren't on Pear'd at all. The server compares those hashes against hashes it already holds for accounts that turned on "let people find me," and never learns which of your contacts, if any, produced a match.</p>
    <p>Searching your own contacts needs no opt-in from you. Being found by someone else's search does — it's off by default, and turning it on is what lets your email (and phone number, if you add one) be matched at all.</p>
    <p>This isn't a cryptographic guarantee: an unsalted hash of a phone number can, in principle, be reversed by brute force by someone motivated enough to try. It's meaningfully better than sending contacts in the clear, not a promise of anonymity — a trade-off we'd rather state plainly than gloss over.</p>

    <h2>Who we share it with</h2>
    <p>We don't sell or share your data with advertisers, and we don't run analytics or tracking in the app. Data passes through:</p>
    <ul>
      <li>Apple or Google, to sign you in.</li>
      <li>Apple's Push Notification service, to deliver alerts to your device.</li>
      <li>The server we operate, where everything above is stored.</li>
    </ul>

    <h2>Retention</h2>
    <p>By default, moments you post stay part of a connection's shared history even if you later leave it — leaving removes your membership, not the record of what already happened, which was somebody else's record of it too. When you leave, the app offers to delete your own moments from that connection instead; choosing that removes them for everyone in it. Your account data is kept for as long as your account exists.</p>

    <h2>Your rights</h2>
    <p>You can sign out at any time from the app, and download a copy of your own profile, connections and moments any time from Settings → Export your data.</p>
    <p>You can delete your account from Settings → Delete account. It happens immediately and takes your profile, your photo, your moments across every connection, your reactions and your push registration with it — you don't have to ask us, and there's nothing to wait for. Any connection you leave behind that still has other people in it keeps its shared history minus your moments; one that had only you is deleted outright.</p>
    <p>If you'd rather we did it, or you want to ask what we hold, email <a href="mailto:` + contactEmail + `">` + contactEmail + `</a> — we'll action requests within 30 days.</p>

    <h2>Children</h2>
    <p>Pear'd is not directed at children under 13, and we don't knowingly collect data from them.</p>

    <h2>Changes</h2>
    <p>If this policy changes, we'll update the date at the top of this page.</p>

    <h2>Contact</h2>
    <p><a href="mailto:` + contactEmail + `">` + contactEmail + `</a></p>
  </div>
`
