#+build windows
#+private file
package p

create :: proc(a: int, b: rawptr) {}
use :: proc() { create(1, nil) }
