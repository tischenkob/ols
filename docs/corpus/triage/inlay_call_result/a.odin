package p

one :: proc() -> int { return 1 }
f :: proc() -> int {
	c := one()
	return c
}
