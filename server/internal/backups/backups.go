// Package backups switches on PocketBase's scheduled backups from the
// environment, so that pb_data — the only state the server has — is copied off
// the box without anybody remembering to do it.
//
// PocketBase already knows how: Settings.Backups takes a cron expression, a
// retention count and an S3-compatible target (R2, B2, S3 itself, MinIO), zips
// pb_data on schedule and uploads it. What it lacked was configuration that
// survives a rebuild. Settings live in the database, which is the very thing
// being backed up; configured from env, a restored or brand-new server backs
// itself up again from its first boot.
//
// Nothing happens unless PEARD_BACKUP_CRON is set. Whatever the dashboard says
// then stands, exactly as before this package existed.
package backups

import (
	"context"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/pocketbase/pocketbase/core"
)

// defaultMaxKeep is how many scheduled backups are kept when
// PEARD_BACKUP_MAX_KEEP is unset: a week of a daily schedule. PocketBase
// insists on a number once there is a schedule, and "keep everything" is a
// bucket that grows until somebody notices the bill.
const defaultMaxKeep = 7

// staleAfter is how old the newest backup may be before the server says so.
// Two days rather than one so that a daily schedule missing a single run — a
// restart across the scheduled minute, say — is not an alarm, while one that
// has stopped altogether is noticed within a day of the miss becoming a
// pattern. It assumes a schedule of at least daily, which is the only kind
// worth having for a server whose data changes all day.
const staleAfter = 48 * time.Hour

// checkSchedule is when the staleness check runs, as well as at boot: a
// server that stays up for weeks would otherwise only ever check once.
const checkSchedule = "17 9 * * *"

// Register applies the configuration on bootstrap, after e.Next() for the same
// reason main.go sets the app URL there: bootstrapping loads the stored
// settings over anything set before it.
//
// Settings are only changed in memory, like limits' rate-limit rules, so the S3
// secret is never written to the database unless somebody saves the settings
// from the dashboard. PocketBase's own scheduler reads Backups.Cron when its
// bootstrap hook resumes, which is after this one returns, so the schedule
// takes effect on this boot rather than the next.
func Register(app core.App) {
	app.OnBootstrap().BindFunc(func(e *core.BootstrapEvent) error {
		if err := e.Next(); err != nil {
			return err
		}
		apply(e.App, os.Getenv)
		return nil
	})
}

func apply(app core.App, getenv func(string) string) {
	cfg, ok, err := fromEnv(getenv)
	if err != nil {
		// Logged rather than fatal. A typo in a backup setting taking the whole
		// server down on deploy is a worse outcome than a server running
		// without backups — and the staleness warning below keeps saying so
		// until it is fixed, which a failed boot would only say once.
		app.Logger().Error("scheduled backups not configured: invalid PEARD_BACKUP_* settings", "error", err)
		return
	}
	if !ok {
		if hasS3Env(getenv) {
			app.Logger().Warn("PEARD_BACKUP_S3_* is set but PEARD_BACKUP_CRON is not, so nothing is scheduled")
		}
		return
	}

	app.Settings().Backups = cfg
	if cfg.S3.Enabled {
		app.Logger().Info("scheduled backups enabled",
			"cron", cfg.Cron, "maxKeep", cfg.CronMaxKeep,
			"bucket", cfg.S3.Bucket, "endpoint", cfg.S3.Endpoint)
	} else {
		// Better than nothing — it survives a bad migration or a mistaken
		// delete — but it is on the same disk as what it protects.
		app.Logger().Warn("scheduled backups enabled without PEARD_BACKUP_S3_BUCKET; "+
			"they are kept in pb_data/backups, on the same disk as the data",
			"cron", cfg.Cron, "maxKeep", cfg.CronMaxKeep)
	}

	// In the background: listing a remote bucket is a network call, and a slow
	// or unreachable one must not hold up the server starting.
	go warnIfStale(app, time.Now())
	app.Cron().Add("peardBackupStaleness", checkSchedule, func() {
		warnIfStale(app, time.Now())
	})
}

var s3Env = []string{
	"PEARD_BACKUP_S3_ENDPOINT",
	"PEARD_BACKUP_S3_BUCKET",
	"PEARD_BACKUP_S3_REGION",
	"PEARD_BACKUP_S3_ACCESS_KEY",
	"PEARD_BACKUP_S3_SECRET",
	"PEARD_BACKUP_S3_FORCE_PATH_STYLE",
}

func hasS3Env(getenv func(string) string) bool {
	return slices.ContainsFunc(s3Env, func(name string) bool {
		return strings.TrimSpace(getenv(name)) != ""
	})
}

// fromEnv maps the PEARD_BACKUP_* variables onto PocketBase's settings.
//
// ok is false when PEARD_BACKUP_CRON is unset, meaning "leave the settings
// alone". The S3 target is switched on by PEARD_BACKUP_S3_BUCKET; with a bucket,
// PocketBase's own validation then insists on the endpoint, region and keys,
// and that validation runs here so a missing one is reported at boot rather
// than at the first scheduled run.
func fromEnv(getenv func(string) string) (core.BackupsConfig, bool, error) {
	env := func(name string) string { return strings.TrimSpace(getenv(name)) }

	cron := env("PEARD_BACKUP_CRON")
	if cron == "" {
		return core.BackupsConfig{}, false, nil
	}

	cfg := core.BackupsConfig{Cron: cron, CronMaxKeep: defaultMaxKeep}
	if raw := env("PEARD_BACKUP_MAX_KEEP"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil {
			return core.BackupsConfig{}, false, fmt.Errorf("PEARD_BACKUP_MAX_KEEP %q is not a number", raw)
		}
		cfg.CronMaxKeep = n
	}

	if bucket := env("PEARD_BACKUP_S3_BUCKET"); bucket != "" {
		cfg.S3 = core.S3Config{
			Enabled:   true,
			Bucket:    bucket,
			Endpoint:  env("PEARD_BACKUP_S3_ENDPOINT"),
			Region:    env("PEARD_BACKUP_S3_REGION"),
			AccessKey: env("PEARD_BACKUP_S3_ACCESS_KEY"),
			Secret:    env("PEARD_BACKUP_S3_SECRET"),
		}
		if raw := env("PEARD_BACKUP_S3_FORCE_PATH_STYLE"); raw != "" {
			v, err := strconv.ParseBool(raw)
			if err != nil {
				return core.BackupsConfig{}, false, fmt.Errorf("PEARD_BACKUP_S3_FORCE_PATH_STYLE %q is not true or false", raw)
			}
			cfg.S3.ForcePathStyle = v
		}
	}

	if err := cfg.Validate(); err != nil {
		return core.BackupsConfig{}, false, err
	}
	return cfg, true, nil
}

// warnIfStale logs a warning when the newest backup in the configured target is
// older than staleAfter, or when there is none.
//
// Every backup counts, not only the scheduled ones: a manual backup taken
// from the dashboard is just as restorable. A backup that fails already
// triggers PocketBase's own error log and superuser email, but a schedule that
// never runs at all — cleared settings, a stopped cron — fails silently, and
// this is what catches it.
func warnIfStale(app core.App, now time.Time) {
	newest, err := newestBackup(app)
	switch {
	case err != nil:
		app.Logger().Warn("could not check the age of the latest backup", "error", err)
	case newest.IsZero():
		// Expected on the first boot after switching backups on, and worth
		// saying on every boot after that.
		app.Logger().Warn("no backups found yet; the first is due at the next scheduled run",
			"cron", app.Settings().Backups.Cron)
	case now.Sub(newest) > staleAfter:
		app.Logger().Warn("the latest backup is out of date",
			"newest", newest.UTC().Format(time.RFC3339),
			"age", now.Sub(newest).Round(time.Hour).String())
	}
}

func newestBackup(app core.App) (time.Time, error) {
	fsys, err := app.NewBackupsFilesystem()
	if err != nil {
		return time.Time{}, err
	}
	defer fsys.Close()

	// A bounded wait, because the goroutine at boot would otherwise hang for
	// as long as an unreachable endpoint takes to give up.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	fsys.SetContext(ctx)

	files, err := fsys.List("")
	if err != nil {
		return time.Time{}, err
	}
	var newest time.Time
	for _, f := range files {
		if strings.HasSuffix(f.Key, ".zip") && f.ModTime.After(newest) {
			newest = f.ModTime
		}
	}
	return newest, nil
}
