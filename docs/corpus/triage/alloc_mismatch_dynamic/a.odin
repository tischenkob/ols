package p

f :: proc() -> int {
	a := make([dynamic]int, 0, 8, context.temp_allocator)
	defer delete(a)
	m := make(map[int]int, context.temp_allocator)
	defer delete(m)
	append(&a, 1)
	m[1] = 1
	return len(a) + len(m)
}
