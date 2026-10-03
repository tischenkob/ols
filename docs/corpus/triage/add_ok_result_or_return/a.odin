package p

Err :: enum { None, Bad }
g :: proc(x: int) -> Err { return .None }
h :: proc(x: int) -> (Err, bool) {
	g(x) or_return
	return .None, true
}
