package tests

import "core:testing"

import test "src:testing"

@(test)
signature_comp_lit_in_call_arg_comes_first :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Info :: struct {
			size: int,
		}

		create :: proc(device: int, info: Info) {}

		main :: proc() {
			create(1, { {*} })
		}
		`,
		config = {enable_comp_lit_signature_help = true},
	}

	test.expect_signature_label_order(
		t,
		&source,
		{"test.Info :: struct {\n\tsize: int,\n}", "test.create :: proc(device: int, info: Info)"},
	)
}

@(test)
signature_call_in_comp_lit_comes_first :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Holder :: struct {
			n: int,
		}

		make_n :: proc(size: int) -> int {
			return size
		}

		main :: proc() {
			h := Holder{n = make_n({*})}
		}
		`,
		config = {enable_comp_lit_signature_help = true},
	}

	test.expect_signature_label_order(
		t,
		&source,
		{"test.make_n :: proc(size: int) -> int", "test.Holder :: struct {\n\tn: int,\n}"},
	)
}
