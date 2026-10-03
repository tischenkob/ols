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
	Failed,
}

Value :: union {
	Parse_Error,
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

flags :: proc() -> (bless, verbose: bool, name: string, ok: bool) {
	return false, false, "", true
}

unnamed :: proc() -> (bool, int) {
	return false, 0
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
		{
			{16, "error-not-last"},
			{20, "error-not-last"},
			{24, "error-not-last"},
			{28, "error-not-last"},
			{36, "error-not-last"},
		},
	)
}

@(test)
lint_result_order_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"named results",
			`package test

Parse_Error :: enum {
	None,
	Bad,
}

f :: proc() -> (err: Parse_Error, v: int) {
	return .None, 0
}
`,
			{{7, "error-not-last"}},
		},
		{
			"an error-like result followed only by errors",
			`package test

Parse_Error :: enum {
	None,
	Bad,
}

f :: proc() -> (int, bool, Parse_Error) {
	return 0, false, .None
}
`,
			{},
		},
		{
			"a procedure type in a struct field",
			`package test

Parse_Error :: enum {
	None,
	Bad,
}

Handler :: struct {
	run: proc() -> (Parse_Error, int),
}
`,
			{{8, "error-not-last"}},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_result_order = true})
}

@(test)
error_not_last_ignores_value_union :: proc(t: ^testing.T) {
	// Corpus: Skald view.odin, reduced, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

Shape :: union { int, f32 }
make_shape :: proc() -> (s: Shape, changed: bool) { return 1, true }
`,
		config = {enable_lint_result_order = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
error_not_last_needs_an_error_like_enum :: proc(t: ^testing.T) {
	// Corpus: an enum with a `None` member is not an error unless its name or another member says so.
	source := test.Source {
		main = `package test

Kind :: enum {
	None,
	Box,
}

Open_Error :: enum {
	None,
	Bad,
}

Outcome :: enum {
	None,
	Invalid_Input,
}

value :: proc() -> (Kind, int) {
	return .Box, 0
}

by_name :: proc() -> (Open_Error, int) {
	return .Bad, 0
}

by_member :: proc() -> (Outcome, int) {
	return .Invalid_Input, 0
}
`,
		config = {enable_lint_result_order = true},
	}

	test.expect_lint_diagnostics(t, &source, {{21, "error-not-last"}, {25, "error-not-last"}})
}
