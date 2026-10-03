package p

Tag :: distinct u16
T1 :: Tag(0x40)
a :: proc($tag: Tag, p: []u8) -> int { return 0 }
b :: proc($tag: Tag, p: ^int) -> int { return 0 }
ab :: proc{a, b}
g :: proc() {
	r1 := ab(T1, nil)
	_ = r1
}
