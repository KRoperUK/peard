package health

import (
	"errors"
	"testing"
)

func TestSnapshotReflectsWhatWasRecorded(t *testing.T) {
	reset()
	RecordJob("invite_sweep", nil, "3 deleted")
	RecordJob("backup_check", errors.New("bucket unreachable"), "ignored")
	RecordPush(true)
	RecordPush(true)
	RecordPush(false)
	Set("apns_configured", true)

	snap := Snapshot()
	jobs := snap["jobs"].(map[string]Job)
	if j := jobs["invite_sweep"]; !j.OK || j.Detail != "3 deleted" || j.LastRun.IsZero() {
		t.Errorf("invite_sweep = %+v", j)
	}
	if j := jobs["backup_check"]; j.OK || j.Detail != "bucket unreachable" {
		t.Errorf("backup_check = %+v, want failed with the error as detail", j)
	}
	push := snap["push"].(map[string]any)
	if push["sent"] != int64(2) || push["failed"] != int64(1) {
		t.Errorf("push = %v, want 2 sent, 1 failed", push)
	}
	if snap["facts"].(map[string]any)["apns_configured"] != true {
		t.Errorf("facts = %v", snap["facts"])
	}
}
