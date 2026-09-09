#+feature dynamic-literals

package tests

import "core:testing"

import test "src:testing"

@(private = "file")
POPULATE :: "populate remaining switch cases"

@(private = "file")
ENUM :: `package test

Color :: enum {
	Red,
	Green,
	Blue,
}

`

@(test)
populate_switch_cases_enum :: proc(t: ^testing.T) {
	source := test.Source {
		main = ENUM + `main :: proc() {
	c := Color.Red
	swi{*}tch c {
	}
}
`,
	}

	test.expect_action_applied(
		t,
		&source,
		POPULATE,
		ENUM + `main :: proc() {
	c := Color.Red
	switch c {
	case .Red:
	case .Green:
	case .Blue:
	}
}
`,
	)
}

@(test)
populate_switch_cases_appends_the_rest :: proc(t: ^testing.T) {
	source := test.Source {
		main = ENUM + `main :: proc() {
	c := Color.Red
	swi{*}tch c {
	case .Red:
		foo()
	}
}
`,
	}

	test.expect_action_applied(
		t,
		&source,
		POPULATE,
		ENUM + `main :: proc() {
	c := Color.Red
	switch c {
	case .Red:
		foo()
	case .Green:
	case .Blue:
	}
}
`,
	)
}

// `#partial` says the missing cases are deliberate, but the action still offers to write them.
@(test)
populate_switch_cases_partial_switch :: proc(t: ^testing.T) {
	source := test.Source {
		main = ENUM + `main :: proc() {
	c := Color.Red
	#partial swi{*}tch c {
	case .Red:
		foo()
	}
}
`,
	}

	test.expect_action_applied(
		t,
		&source,
		POPULATE,
		ENUM +
		`main :: proc() {
	c := Color.Red
	#partial switch c {
	case .Red:
		foo()
	case .Green:
	case .Blue:
	}
}
`,
	)
}

@(test)
populate_switch_cases_union :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Value :: union {
	int,
	bool,
}

main :: proc() {
	v: Value
	swi{*}tch t in v {
	}
}
`,
	}

	test.expect_action_applied(
		t,
		&source,
		POPULATE,
		`package test

Value :: union {
	int,
	bool,
}

main :: proc() {
	v: Value
	switch t in v {
	case int:
	case bool:
	}
}
`,
	)
}

@(test)
populate_switch_cases_complete :: proc(t: ^testing.T) {
	source := test.Source {
		main = ENUM + `main :: proc() {
	c := Color.Red
	swi{*}tch c {
	case .Red:
	case .Green:
	case .Blue:
	}
}
`,
	}

	test.expect_action_missing(t, &source, POPULATE)
}

@(test)
populate_switch_cases_imported_enum :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:paint"

main :: proc() {
	c := paint.Color.Red
	swi{*}tch c {
	}
}
`,
		packages = {{pkg = "paint", source = `package paint

Color :: enum {
	Red,
	Green,
}
`}},
		collections = {"core" = "test"},
	}

	test.expect_action_applied(
		t,
		&source,
		POPULATE,
		`package test

import "core:paint"

main :: proc() {
	c := paint.Color.Red
	switch c {
	case .Red:
	case .Green:
	}
}
`,
	)
}
