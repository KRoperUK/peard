package pairs

import (
	"fmt"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// registerLifecycle enforces one invariant: a connection with no members does
// not persist.
//
// It hangs off `pair_members` deletion rather than off the /leave route, because
// a membership row disappears through four different doors and only one of them
// is that route:
//
//   - POST /api/peard/pairs/leave
//   - DELETE /api/collections/pair_members/{id} — the collection DeleteRule is
//     `user = @request.auth.id`, so any client can delete its own membership
//     directly and never call the route at all
//   - deleting a user, which cascades through `pair_members.user`; that is the
//     Apple `account-delete` erase path, and a superuser deleting somebody from
//     the dashboard
//   - deleting the pair itself, which cascades the other way
//
// Guarding only the route would leave the other three producing exactly the
// orphan this is meant to prevent. Guarding the model covers all four with one
// rule, and the last one is a no-op because the pair is already gone by the time
// its members cascade (PocketBase deletes the main record before its references).
//
// Why it matters that these do not linger: every access rule scopes membership
// through a back-relation LEFT JOIN, so a memberless pair used to be readable
// with no Authorization header at all — see the 1785715200_peard_auth_guard
// migration. That hole is closed, but an orphan still keeps everybody's moments,
// notes and photos on disk for a connection that no longer exists, and nobody is
// left who could delete them.
//
// The same four doors can take away a group's only owner, so the hook also
// keeps a second invariant: a connection that still has members has an owner.
// See ensureOwner.
func registerLifecycle(app core.App) {
	// OnRecordDeleteExecute rather than OnRecordAfterDeleteSuccess: the success
	// hook fires only once the delete has committed, which would leave the pair
	// deletion in a second transaction that can fail on its own. Wrapping
	// e.Next() in a transaction here — the pattern PocketBase's own
	// TestTransactionFromInnerDeleteHook demonstrates — makes losing the last
	// member and deleting the connection one atomic act, so a failure leaves the
	// member in place rather than half-dismantling the connection.
	app.OnRecordDeleteExecute("pair_members").BindFunc(func(e *core.RecordEvent) error {
		pairID := e.Record.GetString("pair")

		originalApp := e.App
		return e.App.RunInTransaction(func(txApp core.App) error {
			e.App = txApp
			defer func() { e.App = originalApp }()

			if err := e.Next(); err != nil {
				return err
			}
			gone, err := deletePairIfEmpty(txApp, pairID)
			if err != nil || gone {
				return err
			}
			_, err = ensureOwner(txApp, pairID)
			return err
		})
	})
}

// DeleteMemberlessPairs removes every connection that currently has no members,
// returning how many it deleted.
//
// registerLifecycle keeps new orphans from appearing; this reconciles the ones
// already there. Used by the 1785801600_peard_orphan_pairs migration, and kept
// here rather than in that file so there is one implementation of "delete a
// connection nobody belongs to" and one place to reason about its blast radius.
func DeleteMemberlessPairs(app core.App) (int, error) {
	pairs, err := app.FindAllRecords("pairs")
	if err != nil {
		return 0, fmt.Errorf("list pairs: %w", err)
	}

	deleted := 0
	for _, pair := range pairs {
		gone, err := deletePairIfEmpty(app, pair.Id)
		if err != nil {
			return deleted, err
		}
		if gone {
			deleted++
		}
	}
	return deleted, nil
}

// BackfillGroupOwners promotes a member in every connection that has members
// but no owner, returning how many it promoted.
//
// registerLifecycle hands the role on from here on; this repairs the groups
// whose owner left or deleted their account before it did. Used by the
// 1786838400_peard_backfill_group_owners migration.
func BackfillGroupOwners(app core.App) (int, error) {
	pairs, err := app.FindAllRecords("pairs")
	if err != nil {
		return 0, fmt.Errorf("list pairs: %w", err)
	}

	promoted := 0
	for _, pair := range pairs {
		did, err := ensureOwner(app, pair.Id)
		if err != nil {
			return promoted, err
		}
		if did {
			promoted++
		}
	}
	return promoted, nil
}

// DeleteExpiredInvites removes every unaccepted invite whose expiry has passed,
// returning how many it deleted.
//
// Deleted rather than marked expired, which is what the sweep used to do. An
// invite that can no longer be redeemed has no further use to anybody: the row
// records who invited whom and when, which is precisely the sort of thing this
// app does not keep once it has stopped being needed, and the code it holds
// occupies a uniquely-indexed slot forever.
//
// Accepted invites are left alone. They are not "unused", and the connection
// they produced is the thing that proves it.
//
// An invite with no expiry at all is also left alone. Nothing this server
// issues is like that — see inviteHandler — so one can only have come from the
// dashboard, and deleting a row somebody deliberately made open-ended because
// an empty date sorts before every real one would be a nasty surprise.
func DeleteExpiredInvites(app core.App, now types.DateTime) (int, error) {
	deleted := 0
	// Batched, and bounded: a sweep that loops until the query comes back empty
	// would spin forever on a delete that keeps failing for the same reason.
	for range inviteSweepBatches {
		invites, err := app.FindRecordsByFilter(
			"pair_invites",
			"status != 'accepted' && expires != '' && expires < {:now}",
			"", inviteSweepBatch, 0,
			dbx.Params{"now": now.String()},
		)
		if err != nil {
			return deleted, fmt.Errorf("find expired invites: %w", err)
		}
		if len(invites) == 0 {
			return deleted, nil
		}
		for _, inv := range invites {
			if err := app.Delete(inv); err != nil {
				return deleted, fmt.Errorf("delete expired invite %s: %w", inv.Id, err)
			}
			deleted++
		}
	}
	return deleted, nil
}

// deletePairIfEmpty deletes a connection that has no members left, cascading to
// its posts, reactions, custom moments, pending invites and uploaded files. It
// reports whether it deleted anything.
//
// Missing and still-occupied are both ordinary outcomes, not errors: the first is
// the pair's own cascade coming back around, the second is somebody leaving a
// group that carries on without them.
func deletePairIfEmpty(app core.App, pairID string) (bool, error) {
	if pairID == "" {
		return false, nil
	}

	pair, err := app.FindRecordById("pairs", pairID)
	if err != nil || pair == nil {
		// Already gone — this delete was the pair's own cascade reaching its
		// members. Nothing to do, and nothing wrong.
		return false, nil
	}

	// Counted with the pair named in any error, so a failure says which
	// connection it could not count.
	remaining, err := app.CountRecords("pair_members", dbx.HashExp{"pair": pairID})
	if err != nil {
		// Deliberately fatal to the surrounding delete rather than swallowed. A
		// failed count is indistinguishable from a count of zero if you ignore
		// it, and treating it as zero would delete a populated connection and
		// every moment in it.
		return false, fmt.Errorf("count members of pair %s: %w", pairID, err)
	}
	if remaining > 0 {
		return false, nil
	}

	if err := app.Delete(pair); err != nil {
		return false, fmt.Errorf("delete emptied pair %s: %w", pairID, err)
	}
	return true, nil
}

// ensureOwner promotes the longest-standing member of a connection that has
// members but no owner, reporting whether it promoted anybody.
//
// Only the owner can remove somebody (see removeHandler), and the role is only
// ever given to whoever created the connection. Without this, an owner leaving
// or deleting their account left a group nobody could remove anyone from.
// Longest-standing because it is the one choice every remaining member can
// predict, and it needs nothing from people who may not be around to give it.
//
// Called after every membership deletion rather than only when the departing
// row was the owner's: it costs one count, and it also repairs a group that
// lost its owner some other way.
func ensureOwner(app core.App, pairID string) (bool, error) {
	if pairID == "" {
		return false, nil
	}
	if pair, err := app.FindRecordById("pairs", pairID); err != nil || pair == nil {
		// The pair's own cascade, as in deletePairIfEmpty: the remaining members
		// are on their way out too, and there is nothing left to own.
		return false, nil
	}

	owners, err := app.CountRecords("pair_members", dbx.HashExp{"pair": pairID, "role": "owner"})
	if err != nil {
		return false, fmt.Errorf("count owners of pair %s: %w", pairID, err)
	}
	if owners > 0 {
		return false, nil
	}

	// `id` breaks ties between memberships created in the same millisecond, so
	// the choice is at least stable.
	eldest, err := app.FindRecordsByFilter("pair_members",
		"pair = {:pair}", "created,id", 1, 0, dbx.Params{"pair": pairID})
	if err != nil {
		return false, fmt.Errorf("find eldest member of pair %s: %w", pairID, err)
	}
	if len(eldest) == 0 {
		return false, nil
	}

	eldest[0].Set("role", "owner")
	if err := app.Save(eldest[0]); err != nil {
		return false, fmt.Errorf("promote owner of pair %s: %w", pairID, err)
	}
	return true, nil
}
