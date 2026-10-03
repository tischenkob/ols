package tests

import "core:testing"

import test "src:testing"

// Gates tests that crash or hang the runner (the runner cannot stop a crashed thread).
// Run them with: ./build.sh single_test NAME -define:ROLS_HANG_TESTS=true
ROLS_HANG_TESTS :: #config(ROLS_HANG_TESTS, false)


// Corpus: reduced, see docs/corpus-validation.md.
@(test)
inlay_unresolved_call_has_no_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	x := undefined_proc(1)
	_ = x
}
`,
		config = {enable_inlay_hints_variable_types = true},
	}
	test.expect_inlay_hints(t, &source)
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
inlay_paren_cast_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(p: rawptr) {
	x[[: ^int]] := (^int)(p)
	_ = x
}
`,
		config = {enable_inlay_hints_variable_types = true},
	}
	test.expect_inlay_hints(t, &source)
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
inlay_make_with_param_length :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Allocator_Error :: enum { None }
make_slice :: proc($T: typeid/[]$E, #any_int len: int, loc := #caller_location) -> (res: T, err: Allocator_Error) #optional_allocator_error { return }
make_dynamic_array_len :: proc($T: typeid/[dynamic]$E, #any_int len: int, loc := #caller_location) -> (array: T, err: Allocator_Error) #optional_allocator_error { return }
make :: proc{make_slice, make_dynamic_array_len}

f :: proc(m: int) {
	x[[: []int]] := make([]int, m)
	_ = x
}
`,
		config = {enable_inlay_hints_variable_types = true},
	}
	test.expect_inlay_hints(t, &source)
}

@(test)
inlay_hints_survive_temp_free :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

one :: proc() -> int { return 1 }

f :: proc() {
	c := one()
	_ = c
}
`,
		config = {enable_inlay_hints_variable_types = true},
	}
	test.expect_inlay_hints_after_temp_free(t, &source, ": int")
}
