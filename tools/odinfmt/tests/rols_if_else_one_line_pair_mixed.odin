// Corpus validation follow-up: a one-line `if` or `when` chain with one `;` block breaks every block when the line does not fit.
package odinfmt_test

f :: proc() {
	if x {a(); b()} else if y {c(); long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, ccccccc)}
	if x {a()} else {c(); long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccc)}
	if x {c(); long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccc)} else {a()}
	when X {a(); b()} else when Y {c(); long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, cc)}
	if x {a()} else if y {b()} else {c(); long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, c)}
	if x {a(); b()} else if y {c()} else {long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbb)}
	if x {a(); b()} else if g(proc() {if q {r()} else {s(); t()}}) {c(); long_call(aaaaaaaaa)}
	if x {a()} else {g(proc() {s(); t()}); long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb)}
	if x {a(); b()} else if y {c(); d()}
	if x {a()} else if y {b()} else {c()}
	if x {a()} else {b()}
}
