package migrations

import (
	"strings"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// An update rule is checked against the record as it stands, not as it will
// be, so `user = @request.auth.id` lets the owner write any other user into
// `user` and hand the record over. Whoever or whatever a record belongs to is
// fixed at creation: the fields below may be resent unchanged (the app sends
// `user` on every device upsert) but never changed.
var lockedOwnerFields = map[string][]string{
	"devices":         {"user"},
	"widget_tokens":   {"user", "token", "expires"},
	"moment_kinds":    {"pair", "created_by", "slug"},
	"live_activities": {"user", "pair"},
}

func unchanged(fields []string) string {
	clauses := make([]string, len(fields))
	for i, f := range fields {
		clauses[i] = "@request.body." + f + ":changed = false"
	}
	return strings.Join(clauses, " && ")
}

func init() {
	m.Register(func(app core.App) error {
		for name, fields := range lockedOwnerFields {
			col, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				return err
			}
			if col.UpdateRule == nil {
				continue
			}
			col.UpdateRule = types.Pointer("(" + *col.UpdateRule + ") && " + unchanged(fields))
			if err := app.Save(col); err != nil {
				return err
			}
		}
		return nil
	}, func(app core.App) error {
		for name, fields := range lockedOwnerFields {
			col, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				return err
			}
			if col.UpdateRule == nil {
				continue
			}
			rule := strings.TrimSuffix(*col.UpdateRule, ") && "+unchanged(fields))
			col.UpdateRule = types.Pointer(strings.TrimPrefix(rule, "("))
			if err := app.Save(col); err != nil {
				return err
			}
		}
		return nil
	})
}
