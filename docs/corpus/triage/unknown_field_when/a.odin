package p

FLAG :: #config(FLAG, false)
when FLAG {
	Cfg :: struct { rate: int }
} else {
	Cfg :: struct {}
}
when FLAG {
	use :: proc() -> Cfg { return Cfg{rate = 1} }
}
