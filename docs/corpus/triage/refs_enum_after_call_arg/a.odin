package p

E :: enum { X, Y }
f :: proc(s: string, e: E) {}
g :: proc(s: string) -> string { return s }
main :: proc() {
	f(g("x"), .Y)
	f("x", .Y)
}
