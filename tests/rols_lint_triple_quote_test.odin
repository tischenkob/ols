package tests

import "core:testing"

import test "src:testing"

@(test)
lint_triple_quote_multiline_raw_strings :: proc(t: ^testing.T) {
	source := test.Source {
		main = """
		package test

		a := `x
		y`
		b := `single`
		c := ```
		  z
		  ```
		d := "x\ny"
		e := `
			indented closing
			`
		""" +
		"\nf := `x\n  \ny`",
		config = {enable_lint_triple_quote = true},
	}

	test.expect_lint_diagnostics(t, &source, {{2, "triple-quote"}})
}

@(test)
lint_triple_quote_quick_fix_keeps_edge_newlines :: proc(t: ^testing.T) {
	source := test.Source {
		main = """
		package test

		f :: proc() {
			s := `{*}
		foo

		bar
		`
			_ = s
		}
		""",
		config = {enable_lint_triple_quote = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use a triple-quoted raw string",
		"""
		package test

		f :: proc() {
			s := ```

			foo

			bar

			```
			_ = s
		}
		""",
	)
}

@(test)
lint_triple_quote_modernize :: proc(t: ^testing.T) {
	source := test.Source {
		main = """
		package test

		TOP :: `
		C:\\path\\n "quoted"
			tabbed`

		g :: proc(s: string) -> string { return s }

		f :: proc() {
			_ = g(`one
		two`)
		}
		""",
		config = {enable_lint_triple_quote = true},
	}

	test.expect_modernized(
		t,
		&source,
		{"triple-quote"},
		"""
		package test

		TOP :: ```

		C:\\path\\n "quoted"
			tabbed
		```

		g :: proc(s: string) -> string { return s }

		f :: proc() {
			_ = g(```
			one
			two
			```)
		}
		""",
	)
}
