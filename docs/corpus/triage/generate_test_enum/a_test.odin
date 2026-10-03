package p

import "core:testing"

@(test)
test_f :: proc(t: ^testing.T) {
	result := f()
	testing.expect_value(t, result, {})
}
