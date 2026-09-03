package tests

import "core:testing"

import test "src:testing"

@(private = "file")
LENS_A :: `package test

foo :: proc() {}

bar :: proc() {}

Point :: struct {}

unused :: proc() {}
`

@(private = "file")
LENS_B :: `package test

main :: proc() {
	foo()
	foo()
	bar()
	p: Point
	_ = p
}
`

@(test)
code_lens_reference_counts :: proc(t: ^testing.T) {
	source := test.Source {
		main   = LENS_A,
		files  = {{"b.odin", LENS_B}},
		config = {enable_code_lens_references = true},
	}
	test.expect_code_lenses(t, &source, {"2 references", "1 reference", "1 reference", "no references"})
}

@(test)
code_lens_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main  = LENS_A,
		files = {{"b.odin", LENS_B}},
	}
	test.expect_code_lenses(t, &source, {})
}
