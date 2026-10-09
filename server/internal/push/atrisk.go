package push

import (
	"time"

	"peard/internal/health"
	"peard/internal/zone"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
)

// The "streak at risk" reminder nudges a person late in their own evening when
// they have a live personal water streak but have not yet reached their goal
// today — the one moment a gentle prompt still saves the streak (#353).
//
// Like the weekly recap, the job runs every hour and each run sends to the
// devices whose own clock reads the reminder hour, using the zone the app
// stores on the device row. Nine in the evening: late enough that "not there
// yet" means something, early enough to still drink it. Hourly on the hour, so
// a half-hour zone gets it at 21:30 rather than skipped.
//
// Only to the person themselves, and only when they have something to lose:
// no streak, or already at goal, is silence. Muting the connection silences it
// here too, as it does every other push.
const (
	atRiskCron = "0 * * * *"
	atRiskHour = 21
)

// defaultWaterTarget mirrors recap.defaultWaterTarget and the app's
// WaterAmount.defaultRecommended: the goal for a member who stored none.
// Duplicated rather than imported for the same reason startOfWeek is — a small
// constant, and importing recap here would couple the push layer to the HTTP one.
const atRiskDefaultTarget = 2000

// maxPairsPerAtRisk bounds one run, like maxPairsPerRecap, to a personal-scale
// deployment rather than a paginated fleet.
const maxPairsPerAtRisk = 10000

func registerAtRisk(app core.App) {
	app.Cron().MustAdd("waterStreakAtRisk", atRiskCron, func() {
		sendAtRiskReminders(app)
		health.RecordJob("water_streak_at_risk", nil, "")
	})
}

func sendAtRiskReminders(app core.App) {
	sendAtRiskRemindersAt(app, time.Now())
}

// atRiskDue reports whether now falls in the reminder's hour — 21:00 to 21:59 —
// on the clock in loc. Asked of the local clock, like recapDue, so a clock
// change needs no special case.
func atRiskDue(now time.Time, loc *time.Location) bool {
	local := now.In(loc)
	return local.Hour() == atRiskHour
}

// sendAtRiskRemindersAt sends to every member whose device clock reads the
// reminder hour and who is one good glass short of keeping a live streak.
func sendAtRiskRemindersAt(app core.App, now time.Time) {
	if n == nil {
		return
	}

	due := dueAtRiskZones(app, now)
	if len(due) == 0 {
		return
	}

	pairs, err := app.FindRecordsByFilter("pairs", "", "", maxPairsPerAtRisk, 0, dbx.Params{})
	if err != nil {
		app.Logger().Error("push: at-risk could not list pairs", "error", err)
		return
	}
	for _, pair := range pairs {
		sendAtRiskFor(app, pair, now, due)
	}
}

// dueAtRiskZones is the set of stored time_zone values whose devices are in the
// reminder hour at now. Checked before any connection, so most hours are one
// small query and nothing more — the same shape as dueZones.
func dueAtRiskZones(app core.App, now time.Time) map[string]bool {
	var rows []struct {
		TimeZone string `db:"time_zone"`
	}
	if err := app.DB().Select("time_zone").Distinct(true).From("devices").All(&rows); err != nil {
		app.Logger().Error("push: at-risk could not read device zones", "error", err)
		return nil
	}
	due := map[string]bool{}
	for _, row := range rows {
		if atRiskDue(now, deviceZone(row.TimeZone)) {
			due[row.TimeZone] = true
		}
	}
	return due
}

func sendAtRiskFor(app core.App, pair *core.Record, now time.Time, due map[string]bool) {
	members, err := app.FindRecordsByFilter("pair_members",
		"pair = {:pair} && muted != true", "", maxFanOut, 0, dbx.Params{"pair": pair.Id})
	if err != nil {
		return
	}
	for _, member := range members {
		userID := member.GetString("user")
		target := member.GetInt("water_recommended")
		if target <= 0 {
			target = atRiskDefaultTarget
		}
		devices, err := app.FindRecordsByFilter("devices",
			"user = {:user}", "", 20, 0, dbx.Params{"user": userID})
		if err != nil {
			continue
		}
		for _, d := range devices {
			t := d.GetString("push_token")
			stored := d.GetString("time_zone")
			if t == "" || !due[stored] {
				continue
			}
			loc := deviceZone(stored)
			if !streakAtRisk(app, pair.Id, userID, loc, target) {
				continue
			}
			today := zone.StartOfDay(now, loc).Format("2006-01-02")
			p := payload.NewPayload().
				AlertTitle("Streak at risk").
				AlertBody("You haven't hit your water goal yet today — a glass or two keeps your streak alive.").
				Sound("default").
				ThreadID("pair-"+pair.Id).
				Custom("pair_id", pair.Id)
			// One per person per local day: a re-run in or after the hour
			// replaces the unread reminder rather than stacking a second.
			collapseID := truncate("atrisk:"+userID+":"+today, apnsCollapseIDMaxBytes)
			if n.send(t, p, apns2.PushTypeAlert, apns2.PriorityLow, collapseID) {
				forgetDevice(app, d)
			}
		}
	}
}

// streakAtRisk reports whether userID has a live personal water streak in this
// connection that today would break: they met their own goal yesterday (so
// there is a run to lose) but have not reached it yet today.
//
// "Met yesterday" stands in for "has a live streak": a streak is live only if
// its most recent qualifying day is today or yesterday, and if today already
// qualified there is nothing at risk — so the one case worth a nudge is exactly
// yesterday-yes, today-not-yet. Computed in the device's own zone, so "today"
// and "yesterday" are the person's days (#344).
func streakAtRisk(app core.App, pairID, userID string, loc *time.Location, target int) bool {
	if target <= 0 {
		return false
	}
	today := zone.StartOfDay(time.Now(), loc)
	yesterday := today.AddDate(0, 0, -1)
	todayTotal := personalWaterOnDay(app, pairID, userID, today, loc)
	if todayTotal >= target {
		return false // already safe; nothing at risk
	}
	yesterdayTotal := personalWaterOnDay(app, pairID, userID, yesterday, loc)
	return yesterdayTotal >= target
}

// personalWaterOnDay sums one member's own water (type=event, with an amount)
// that falls on the given local day in loc. The day's bounds are built from the
// IANA zone so a clock change does not misplace a glass logged near midnight.
func personalWaterOnDay(app core.App, pairID, userID string, day time.Time, loc *time.Location) int {
	start := zone.StartOfDay(day, loc)
	end := start.AddDate(0, 0, 1)
	var rows []struct {
		Amount int `db:"amount"`
	}
	err := app.DB().
		Select("COALESCE(amount, 0) AS amount").
		From("posts").
		Where(dbx.NewExp(
			"pair = {:pair} AND author = {:user} AND type = 'event'"+
				" AND happened_at >= {:start} AND happened_at < {:end}",
			dbx.Params{
				"pair":  pairID,
				"user":  userID,
				"start": start.UTC().Format("2006-01-02 15:04:05.000Z"),
				"end":   end.UTC().Format("2006-01-02 15:04:05.000Z"),
			})).
		All(&rows)
	if err != nil {
		return 0
	}
	total := 0
	for _, r := range rows {
		total += r.Amount
	}
	return total
}
