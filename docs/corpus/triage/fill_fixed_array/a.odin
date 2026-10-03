package p

import "core:slice"

f :: proc() -> [8]u8 {
	buf: [8]u8
	slice.fill(buf, 'a')
	return buf
}
