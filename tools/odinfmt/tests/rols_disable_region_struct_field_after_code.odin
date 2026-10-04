// Corpus: a struct field after `}, // odinfmt:disable` printed its region from the line start and repeated the `}`.
package odinfmt_test

V :: struct {
	a: int,
	b:   struct {
		x:   int,
	}, // odinfmt:disable
	c:    int,
	// odinfmt:enable
	d:    int,
}
