# Device checklist

Things that cannot be settled in the simulator, collected so they take one
sitting rather than six.

Two kinds of item are here. **Unverified** means it was built and never looked
at — synthetic taps and the simulator's Lock Screen were not up to it. **Needs a
device** means no simulator could have answered it.

---

## Part 1 — Unverified UI (about five minutes)

Seven things shipped that nobody has seen on a device. Each is a glance.

Number 7 has been seen in the simulator — the framing, the letterbox and the
rotation all render correctly there. What the simulator could not do is *take a
photo*: its camera shows a grey frame and its shutter does nothing, so the whole
capture-to-send path has only ever run from the photo library.

| # | Where | What to look for |
|---|---|---|
| 1 | Long-press the app icon | Beer, Loo, Coffee appear. Tap one — a moment logs, and the app opens on it |
| 2 | Settings → App icon | Four pears. Tap Amber; iOS shows its own confirmation; the home-screen icon changes |
| 3 | Control Centre → edit → add a control | "Log a Beer" / Coffee / Loo are listed under Pear'd. Add one, tap it, check the moment lands |
| 4 | Lock Screen → customise → add a widget | Pear'd offers rectangular, circular and inline. All three render, and the emoji is legible desaturated |
| 5 | Home screen, **small** widget with a recent photo | The photo fills the tile and the caption bar over it is readable |
| 6 | Share a photo | The "What is it?" sheet appears. Pick Coffee → it lands as a coffee **and** shows the picture. Skip → a plain photo, as before |
| 7 | On that sheet, after taking a picture | Square preview, Fill/Fit, a rotate button and a caption box. Drag to reframe, pinch to zoom. Send → what you framed is what arrives, caption and all |

If any of these is wrong, it is almost certainly a layout or a name, not a
design — tell me which number and I can fix it without a round trip.

### Also, if you signed in with Apple and hid your email

Settings → Discoverable → turn it on. An "Email people have for you" field
should appear above the phone number, with a footer explaining that the relay
address cannot be matched. Enter a real address and save. Nobody has seen this
row; the server half of it is verified.

---

## Part 2 — Accessibility (about fifteen minutes)

This is the part that decides what can honestly be ticked in App Store Connect.
Four features are already supportable on the evidence:

- **Dark Interface** — every colour has a dark variant
- **Differentiate Without Color Alone** — selection uses a ring *and* weight *and* a trait
- **Sufficient Contrast** — every pair measures ≥ 4.5:1 in both schemes, asserted by a test
- **Reduced Motion** — `ReduceMotionAnimation` gates the animations; the photo viewer's zoom is gated separately

Three cannot be claimed without you, because the declaration is about
*completing common tasks*, not about annotations existing.

### The common tasks

Do each of these end to end. If you can finish it without sighted guessing, it
passes.

1. Sign in
2. Log a moment
3. Read the timeline and tell who posted what
4. Share a photo
5. Add a connection

### VoiceOver

Settings → Accessibility → VoiceOver, then run the five tasks by swiping and
double-tapping only.

Watch for:

- **The moment grid** — each tile should say "Log Coffee", not "Coffee" alone
- **The connection rail** — the selected one should announce as *selected*
- **The tallies row** — this is the one I would expect to fail. It reads counts
  as separate labels and has no `accessibilityValue` anywhere in the app; "6"
  next to a coffee cup may announce as nothing useful
- **The quick-send countdown** — a three-second window is short for VoiceOver.
  If it expires before the note field is reachable, that is a real bug and worth
  telling me about

### Larger Text

Settings → Accessibility → Display & Text Size → Larger Text, drag to the
largest **accessibility** size (past the normal range), then run the tasks.

Known gaps, so check these first:

- **The unread badge on the connection rail** is fixed at 9pt and will not grow
- **The privacy consent body** is fixed at 18pt
- Everything else uses semantic fonts and should scale — what matters is whether
  anything *clips or overlaps* rather than whether it grows

### Voice Control

Settings → Accessibility → Voice Control. Try "tap Beer", "tap Timeline", "tap
Share a photo". It works off the same labels VoiceOver reads, so if VoiceOver is
clean this usually is too — but the moment tiles are the ones to try, since
their label ("Log Coffee") differs from their visible text ("Coffee").

---

## What to tell me

For each item: **pass**, or what you saw. "Number 4, circular one is a grey
blob" is enough — I do not need a diagnosis, and a photo of the screen is
better than a description.
