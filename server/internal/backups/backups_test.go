package backups

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

func envOf(vars map[string]string) func(string) string {
	return func(name string) string { return vars[name] }
}

var fullS3 = map[string]string{
	"PEARD_BACKUP_CRON":                "0 3 * * *",
	"PEARD_BACKUP_MAX_KEEP":            "14",
	"PEARD_BACKUP_S3_ENDPOINT":         "https://abc123.r2.cloudflarestorage.com",
	"PEARD_BACKUP_S3_BUCKET":           "peard-backups",
	"PEARD_BACKUP_S3_REGION":           "auto",
	"PEARD_BACKUP_S3_ACCESS_KEY":       "access",
	"PEARD_BACKUP_S3_SECRET":           "secret",
	"PEARD_BACKUP_S3_FORCE_PATH_STYLE": "true",
}

func TestEveryVariableLandsInItsSetting(t *testing.T) {
	cfg, ok, err := fromEnv(envOf(fullS3))
	if err != nil || !ok {
		t.Fatalf("fromEnv: ok=%v err=%v", ok, err)
	}
	want := core.BackupsConfig{
		Cron:        "0 3 * * *",
		CronMaxKeep: 14,
		S3: core.S3Config{
			Enabled:        true,
			Bucket:         "peard-backups",
			Region:         "auto",
			Endpoint:       "https://abc123.r2.cloudflarestorage.com",
			AccessKey:      "access",
			Secret:         "secret",
			ForcePathStyle: true,
		},
	}
	if cfg != want {
		t.Fatalf("got %+v\nwant %+v", cfg, want)
	}
}

// Unset means the settings are left exactly as they are, so a server
// configured from the dashboard before this existed is not switched off.
func TestNoScheduleMeansNoChange(t *testing.T) {
	_, ok, err := fromEnv(envOf(map[string]string{"PEARD_BACKUP_S3_BUCKET": "b"}))
	if ok || err != nil {
		t.Fatalf("ok=%v err=%v, want nothing to apply", ok, err)
	}

	app := newApp(t)
	app.Settings().Backups.Cron = "0 1 * * *"
	app.Settings().Backups.CronMaxKeep = 3
	apply(app, envOf(nil))
	if got := app.Settings().Backups; got.Cron != "0 1 * * *" || got.CronMaxKeep != 3 {
		t.Fatalf("settings changed to %+v with nothing set", got)
	}
}

// A schedule on its own backs up to pb_data/backups, and PocketBase will not
// take a schedule without a retention count, so one is supplied.
func TestAScheduleAloneKeepsAWeekLocally(t *testing.T) {
	cfg, ok, err := fromEnv(envOf(map[string]string{"PEARD_BACKUP_CRON": "0 3 * * *"}))
	if err != nil || !ok {
		t.Fatalf("fromEnv: ok=%v err=%v", ok, err)
	}
	if cfg.S3.Enabled {
		t.Error("S3 switched on with no bucket")
	}
	if cfg.CronMaxKeep != 7 {
		t.Errorf("max keep %d, want the default of 7", cfg.CronMaxKeep)
	}
}

func TestBadValuesAreRefused(t *testing.T) {
	cases := map[string]map[string]string{
		"a cron expression that isn't one": {"PEARD_BACKUP_CRON": "every night"},
		"a retention that isn't a number":  {"PEARD_BACKUP_CRON": "0 3 * * *", "PEARD_BACKUP_MAX_KEEP": "seven"},
		"a retention of nothing":           {"PEARD_BACKUP_CRON": "0 3 * * *", "PEARD_BACKUP_MAX_KEEP": "0"},
		"path style that isn't a bool": {
			"PEARD_BACKUP_CRON": "0 3 * * *", "PEARD_BACKUP_S3_BUCKET": "b",
			"PEARD_BACKUP_S3_FORCE_PATH_STYLE": "sometimes",
		},
	}
	// A bucket without the rest of what S3 needs, one field missing at a time.
	for _, name := range []string{"PEARD_BACKUP_S3_ENDPOINT", "PEARD_BACKUP_S3_REGION", "PEARD_BACKUP_S3_ACCESS_KEY", "PEARD_BACKUP_S3_SECRET"} {
		vars := map[string]string{}
		for k, v := range fullS3 {
			vars[k] = v
		}
		delete(vars, name)
		cases["a bucket without "+name] = vars
	}

	for why, vars := range cases {
		if _, ok, err := fromEnv(envOf(vars)); err == nil || ok {
			t.Errorf("%s: ok=%v err=%v, want an error", why, ok, err)
		}
	}
}

// Invalid settings leave the existing ones alone rather than half-applying.
func TestInvalidSettingsAreNotApplied(t *testing.T) {
	app := newApp(t)
	app.Settings().Backups.Cron = "0 1 * * *"
	app.Settings().Backups.CronMaxKeep = 3

	apply(app, envOf(map[string]string{"PEARD_BACKUP_CRON": "0 3 * * *", "PEARD_BACKUP_MAX_KEEP": "seven"}))

	if got := app.Settings().Backups; got.Cron != "0 1 * * *" {
		t.Fatalf("settings changed to %+v by an invalid configuration", got)
	}
}

// The part that matters: PocketBase's scheduler reads the setting in its own
// bootstrap hook, so this checks that it sees the value from the environment
// on the same boot rather than the stored one.
func TestTheScheduleIsRunningAfterBoot(t *testing.T) {
	dir := t.TempDir()

	// A schedule saved from the dashboard on an earlier boot, which bootstrap
	// loads over anything set before it.
	earlier := core.NewBaseApp(core.BaseAppConfig{DataDir: dir})
	if err := earlier.Bootstrap(); err != nil {
		t.Fatalf("first bootstrap: %v", err)
	}
	earlier.Settings().Backups.Cron = "0 1 * * *"
	earlier.Settings().Backups.CronMaxKeep = 2
	if err := earlier.Save(earlier.Settings()); err != nil {
		t.Fatalf("save settings: %v", err)
	}
	_ = earlier.ResetBootstrapState()

	t.Setenv("PEARD_BACKUP_CRON", "0 3 * * *")
	app := core.NewBaseApp(core.BaseAppConfig{DataDir: dir})
	Register(app)
	if err := app.Bootstrap(); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}
	t.Cleanup(func() { _ = app.ResetBootstrapState() })

	for _, job := range app.Cron().Jobs() {
		if job.Id() == "__pbAutoBackup__" {
			if got := job.Expression(); got != "0 3 * * *" {
				t.Fatalf("backup job runs on %q, want 0 3 * * *", got)
			}
			return
		}
	}
	t.Fatal("no backup job scheduled after boot")
}

// The staleness check counts any backup zip, scheduled or manual, and only
// those.
func TestNewestBackupIsTheLatestZip(t *testing.T) {
	app := newApp(t)
	dir := filepath.Join(app.DataDir(), core.LocalBackupsDirName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Truncate(time.Second)
	for name, age := range map[string]time.Duration{
		"@auto_pb_backup_old.zip": 72 * time.Hour,
		"manual.zip":              30 * time.Hour,
		"notes.txt":               time.Hour,
	} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, now.Add(-age), now.Add(-age)); err != nil {
			t.Fatal(err)
		}
	}

	newest, err := newestBackup(app)
	if err != nil {
		t.Fatalf("newestBackup: %v", err)
	}
	if want := now.Add(-30 * time.Hour); !newest.Equal(want) {
		t.Fatalf("newest %v, want %v (the manual zip)", newest, want)
	}
}

func TestNoBackupsIsAZeroTime(t *testing.T) {
	newest, err := newestBackup(newApp(t))
	if err != nil || !newest.IsZero() {
		t.Fatalf("newest=%v err=%v, want zero and no error", newest, err)
	}
}

func TestTheStalenessThresholdToleratesOneMissedDailyRun(t *testing.T) {
	if staleAfter <= 24*time.Hour || staleAfter > 72*time.Hour {
		t.Fatalf("staleAfter %v: one missed daily run should not warn, three should", staleAfter)
	}
}

func newApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestApp(t.TempDir())
	if err != nil {
		t.Fatalf("new test app: %v", err)
	}
	t.Cleanup(app.Cleanup)
	return app
}
