package export

// SetPageSize shrinks the query page for a test, so paging past the first page
// can be exercised with a handful of records rather than hundreds. It returns
// a function that puts the old size back.
func SetPageSize(n int) (restore func()) {
	old := pageSize
	pageSize = n
	return func() { pageSize = old }
}
