package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"

	"peard/internal/pairs"
)

// Delete connections that already have no members.
//
// Going forward the invariant is enforced on the model — see
// internal/pairs/lifecycle.go — but that only governs deletions from here on.
// Databases predating it hold orphans: leaving used to delete the `pair_members`
// row and nothing deleted the connection behind it, and the debug seed helper
// creates a pair and adds its members in two separate requests, so a failure
// between them strands one. Two were found on the development database.
//
// An orphan is not merely untidy. It keeps every member's moments, notes and
// uploaded photos for a connection nobody belongs to, so nobody is left who could
// delete them — and until the 1785715200_peard_auth_guard migration, the
// membership LEFT JOIN in every access rule made exactly these pairs readable
// with no Authorization header.
//
// Deleting the pair cascades to its posts (and their reactions), its custom
// moments and its pending invites, and PocketBase removes the uploaded files with
// the records. There is no reachable owner to ask first, which is the whole point.
func init() {
	m.Register(func(app core.App) error {
		_, err := pairs.DeleteMemberlessPairs(app)
		return err
	}, func(app core.App) error {
		// Irreversible: the deleted connections and their moments are gone. A
		// down migration that recreated empty pairs would restore the defect
		// without restoring any of the data, so this is deliberately a no-op.
		return nil
	})
}
