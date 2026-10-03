#+build linux
package p

setname :: proc(id: u64, name: cstring) {}
f :: proc() { setname(0, "x") }
