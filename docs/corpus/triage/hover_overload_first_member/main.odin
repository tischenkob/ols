package p

import "lib"
f :: proc() {
	v := 1
	lib.send(&v)
}
