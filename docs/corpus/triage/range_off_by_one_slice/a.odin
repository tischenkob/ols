package p

prefixes :: proc(s: string) -> int {
	n := 0
	for b in 0 ..= len(s) {
		n += len(s[:b])
	}
	return n
}
