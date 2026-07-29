package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Require a signed-in caller before any scoped rule is evaluated.
//
// Every Pear'd rule scopes by membership through a back-relation, e.g.
//
//	pair_members_via_pair.user ?= @request.auth.id
//
// which PocketBase compiles to a LEFT JOIN. For a pair with **no members** the
// joined `user` is NULL, and comparing NULL against the empty `@request.auth.id`
// of an unauthenticated request matched. So a memberless connection — and, through
// the same join, its posts, its reactions and its custom moments — was readable
// with no Authorization header at all.
//
// That is not a hypothetical state. Leaving a connection deletes the
// `pair_members` row and nothing deletes the connection behind it, so the last
// person to leave published the whole shared timeline, notes included. It was
// found on a live database: `GET /api/collections/pairs/records` with no token
// returned two rows, both memberless.
//
// A signed-in stranger was never affected — NULL never equals their real id — so
// the fix is only to reject the empty case, up front, before the join is
// considered. `@request.auth.id != ""` is PocketBase's idiom for that.
//
// Applied uniformly rather than only to the rules with a proven hole. The failure
// was one clause in one rule behaving differently from how it reads, and the cost
// of an audit that has to reason per-rule about whether an empty id can satisfy it
// is much higher than the cost of a prefix that makes "guests get nothing" true by
// construction.
func init() {
	m.Register(func(app core.App) error {
		for _, name := range guardedCollections {
			col, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				return fmt.Errorf("find %s: %w", name, err)
			}
			guardCollectionRules(col)
			if err := app.Save(col); err != nil {
				return fmt.Errorf("save %s: %w", name, err)
			}
		}
		return nil
	}, func(app core.App) error {
		for _, name := range guardedCollections {
			col, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				continue
			}
			unguardCollectionRules(col)
			if err := app.Save(col); err != nil {
				return err
			}
		}
		return nil
	})
}

// guardedCollections are every collection whose rules reference the caller.
// `users` is included for completeness even though `id = @request.auth.id` has no
// hole — no record has an empty id — so that the invariant "every rule starts by
// requiring auth" holds without exceptions to remember.
var guardedCollections = []string{
	"users", "pairs", "pair_members", "posts", "reactions", "moment_kinds", "devices", "widget_tokens",
}

const authGuard = `@request.auth.id != ""`

func guardCollectionRules(col *core.Collection) {
	col.ListRule = guard(col.ListRule)
	col.ViewRule = guard(col.ViewRule)
	col.CreateRule = guard(col.CreateRule)
	col.UpdateRule = guard(col.UpdateRule)
	col.DeleteRule = guard(col.DeleteRule)
}

// guard prefixes a rule with the auth check.
//
// A nil rule means superuser-only and must stay nil — prefixing it would *open*
// the collection to every signed-in user, which is the opposite of the intent. An
// empty non-nil rule means "anybody"; none of Pear'd's collections use that, and
// if one ever did, turning it into "any signed-in user" would be a change of
// meaning rather than a fix, so it is left alone too.
func guard(rule *string) *string {
	if rule == nil || *rule == "" {
		return rule
	}
	if *rule == authGuard {
		return rule
	}
	// Already guarded — migrations must be idempotent because `migrate up` may be
	// run against a database that has partially applied.
	if len(*rule) >= len(authGuard) && (*rule)[:len(authGuard)] == authGuard {
		return rule
	}
	// Parenthesised because the existing rule may be a top-level `||`, and
	// `a != "" && b || c` binds as `(a != "" && b) || c` — which would leave the
	// hole open through `c`.
	return types.Pointer(authGuard + " && (" + *rule + ")")
}

func unguardCollectionRules(col *core.Collection) {
	col.ListRule = unguard(col.ListRule)
	col.ViewRule = unguard(col.ViewRule)
	col.CreateRule = unguard(col.CreateRule)
	col.UpdateRule = unguard(col.UpdateRule)
	col.DeleteRule = unguard(col.DeleteRule)
}

func unguard(rule *string) *string {
	if rule == nil {
		return rule
	}
	prefix := authGuard + " && ("
	if len(*rule) > len(prefix)+1 && (*rule)[:len(prefix)] == prefix && (*rule)[len(*rule)-1] == ')' {
		return types.Pointer((*rule)[len(prefix) : len(*rule)-1])
	}
	return rule
}
