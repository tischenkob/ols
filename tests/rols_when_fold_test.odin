package tests

import "core:testing"

import test "src:testing"

// A file-level `when` reads a constant that names another one declared further down the file.
@(test)
when_fold_forward_reference_at_file_level :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

ON :: !FLAG

FLAG :: true

when ON {
	X :: 1
} else {
	X :: "s"
}

main :: proc() {
	y := X{*}
}
`,
	}
	test.expect_hover(t, &source, `test.X :: "s"`)
}

// A `when` in a procedure folds the package constants in dependency order, whatever order the globals map holds.
@(test)
when_fold_dependency_order_in_procedure :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

ON_1 :: !FLAG_1
ON_2 :: !FLAG_2
ON_3 :: !FLAG_3
ON_4 :: !FLAG_4
ON_5 :: !FLAG_5
ON_6 :: !FLAG_6
ON_7 :: !FLAG_7
ON_8 :: !FLAG_8

FLAG_1 :: true
FLAG_2 :: true
FLAG_3 :: true
FLAG_4 :: true
FLAG_5 :: true
FLAG_6 :: true
FLAG_7 :: true
FLAG_8 :: true

main :: proc() {
	when ON_1 || ON_2 || ON_3 || ON_4 || ON_5 || ON_6 || ON_7 || ON_8 {
		v := 1
	} else {
		v := "s"
	}
	w := v{*}
}
`,
	}
	test.expect_hover(t, &source, "test.v: string")
}
