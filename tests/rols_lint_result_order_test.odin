package tests

import "core:testing"

import test "src:testing"

@(test)
lint_error_not_last :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Parse_Error :: enum {
	Bad,
}

Status :: enum {
	None,
	Busy,
}

Value :: union {
	int,
	string,
}

bad_suffix :: proc() -> (Parse_Error, int) {
	return .Bad, 0
}

bad_enum :: proc() -> (Status, int) {
	return .None, 0
}

bad_bool :: proc() -> (ok: bool, n: int) {
	return false, 0
}

bad_union :: proc() -> (Value, int) {
	return nil, 0
}

good :: proc() -> (int, Parse_Error) {
	return 0, .Bad
}

single :: proc() -> Parse_Error {
	return .Bad
}

foreign import lib "system:lib"

foreign lib {
	c_call :: proc() -> (Parse_Error, int) ---
}
`,
		config = {enable_lint_result_order = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{16, "error-not-last"}, {20, "error-not-last"}, {24, "error-not-last"}, {28, "error-not-last"}},
	)
}
