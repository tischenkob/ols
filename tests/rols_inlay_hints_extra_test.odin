#+feature dynamic-literals

package tests

import "core:testing"

import test "src:testing"

@(test)
inlay_comp_lit_fields :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Point :: struct {
			x: int,
			y: int,
		}

		Wrapper :: struct {
			using point: Point,
			label:       string,
		}

		main :: proc() {
			a := Point{[[x: ]]1, [[y: ]]2}
			b := Point{y = 2}
			c := Wrapper{1, 2, "hi"}
		}
		`,
		packages = {},
		config = {enable_inlay_hints_comp_lit_fields = true},
	}

	test.expect_inlay_hints(t, &source)
}

@(test)
inlay_range_types :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		main :: proc() {
			m: map[string]int
			s: []int

			for k[[: string]], v[[: int]] in m {
			}

			for item[[: int]], _ in s {
			}
		}
		`,
		packages = {},
		config = {enable_inlay_hints_range_types = true},
	}

	test.expect_inlay_hints(t, &source)
}

@(test)
inlay_constant_values :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		WIDTH :: 4
		SIZE :: WIDTH * 2[[ = 8]]
		MASK :: (1 << 3) | 1[[ = 9]]
		NAME :: "a" + "b"[[ = "ab"]]
		FLAG :: !true && false[[ = false]]
		SCALE :: 1.5 * 2.0
		COUNT :: len("abc")

		main :: proc() {
			LOCAL :: WIDTH + 1[[ = 5]]
			_ = LOCAL
		}
		`,
		packages = {},
		config = {enable_inlay_hints_constant_values = true},
	}

	test.expect_inlay_hints(t, &source)
}

// The hint is display text, so it may name a package the file does not import.
@(test)
inlay_variable_type_of_unimported_package :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		import "other"

		main :: proc() {
			n[[: c.int]] := other.count()
		}
		`,
		packages = {
			{pkg = "other", source = "package other\n\nimport \"core:c\"\n\ncount :: proc() -> c.int {\n\treturn 4\n}\n"},
			{pkg = "c", source = "package c\n\nint :: i32\n"},
		},
		collections = {"core" = "test"},
		config = {enable_inlay_hints_variable_types = true},
	}

	test.expect_inlay_hints(t, &source)
}

// A local copied from a variable of an inline struct type has no type name, so it gets no type hint.
@(test)
inlay_variable_type_skips_inline_struct :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		main :: proc() {
			p: struct {
				a: int,
			}
			x := p
			y[[: int]] := p.a
		}
		`,
		packages = {},
		config = {enable_inlay_hints_variable_types = true},
	}

	test.expect_inlay_hints(t, &source)
}
