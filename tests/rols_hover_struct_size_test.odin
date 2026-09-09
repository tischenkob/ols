package tests

import "core:testing"

import test "src:testing"

@(test)
hover_struct_size :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		P :: struct {
			a: u8,
			b: i32,
		}

		main :: proc() {
			P{*}
		}
		`,
		config = {enable_hover_struct_size = true},
	}

	test.expect_hover(t, &source, "test.P :: struct {\n\ta: u8,\n\tb: i32,\n}\n---\nsize: 8 bytes, align: 4")
}

@(test)
hover_field_offset :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		P :: struct {
			a: u8,
			b: i32,
		}

		main :: proc() {
			p: P
			p.b{*}
		}
		`,
		config = {enable_hover_struct_size = true},
	}

	test.expect_hover(t, &source, "P.b: i32\n---\noffset: 4, size: 4")
}

@(test)
hover_packed_size :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		P :: struct #packed {
			a: u8,
			b: i32,
		}

		main :: proc() {
			P{*}
		}
		`,
		config = {enable_hover_struct_size = true},
	}

	test.expect_hover(t, &source, "test.P :: struct #packed {\n\ta: u8,\n\tb: i32,\n}\n---\nsize: 5 bytes, align: 1")
}

@(test)
hover_poly_struct_no_size :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		P :: struct($T: typeid) {
			a: T,
		}

		main :: proc() {
			P{*}
		}
		`,
		config = {enable_hover_struct_size = true},
	}

	test.expect_hover(t, &source, "test.P :: struct($T: typeid) {\n\ta: T,\n}")
}

@(test)
hover_mixed_struct_size :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Color :: enum u8 {Red, Green, Blue}

		Mixed :: struct {
			name:  string,
			items: []int,
			flags: bit_set[Color],
			count: u16,
			fixed: [3]u8,
			tag:   union{u8, i32},
			m:     map[string]int,
			d:     [dynamic]f32,
			p:     ^Mixed,
			e:     Color,
		}

		main :: proc() {
			mixed: Mixed
			mixed.m{*}
		}
		`,
		config = {enable_hover_struct_size = true},
	}

	test.expect_hover(t, &source, "Mixed.m: map[string]int\n---\noffset: 48, size: 32")
}
