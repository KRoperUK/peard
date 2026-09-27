// Package access has no implementation. It exists to hold the cross-connection
// access-control suite, which is the only test that spans every collection rule
// and every custom route at once.
//
// The property under test is one sentence: you may see another person's
// information only if you share a connection with them. That is not enforced in
// one place — it is the sum of seven collection rules, three route-level
// membership checks, and protected files whose view rules open a user's avatar
// to the people who share a connection with them (see
// migrations/1786233600_peard_protect_avatars.go). A unit test in any single
// package can only prove a fragment of it, and a fragment is not the claim
// worth making.
//
// Kept in its own package rather than added to one of the feature packages so it
// can import all of them without a cycle, and so a reader looking for "how do we
// know this holds" finds one file.
package access
