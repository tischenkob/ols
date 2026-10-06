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

// A default clause already handles the missing cases, so listing them would change what runs.
@(test)
populate_switch_cases_default_clause :: proc(t: ^testing.T) {
	source := test.Source {
		main = ENUM + `main :: proc() {
	c := Color.Red
	#partial swi{*}tch c {
	case .Red:
		foo()
	case:
		bar()
	}
}
`,
	}

	test.expect_action_missing(t, &source, POPULATE)
}

@(test)
populate_switch_cases_union_default_clause :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Shape :: union {
	int,
	f32,
	string,
}

f :: proc(s: Shape) -> int {
	#partial swi{*}tch v in s {
	case int:
		return 1
	case:
		return 0
	}
	return 2
}
`,
	}

	test.expect_action_missing(t, &source, POPULATE)
}

@(private = "file")
ALIASED :: `package test

Kind :: enum u32 {
	A = 1,
	B = 2,
	C = 3,
	FIRST = A,
	LAST = C,
	D,
	E = 2,
}

`

// An alias or a repeated value shares the case of the earlier member, so it gets no case of its own.
@(test)
populate_switch_cases_enum_aliases :: proc(t: ^testing.T) {
	source := test.Source {
		main = ALIASED + `f :: proc(k: Kind) {
	#partial swi{*}tch k {
	case .FIRST:
	}
}
`,
	}

	test.expect_action_applied(
		t,
		&source,
		POPULATE,
		ALIASED + `f :: proc(k: Kind) {
	#partial switch k {
	case .FIRST:
	case .B:
	case .C:
	case .D:
	}
}
`,
	)
}

@(test)
populate_switch_cases_enum_aliases_complete :: proc(t: ^testing.T) {
	source := test.Source {
		main = ALIASED + `f :: proc(k: Kind) {
	swi{*}tch k {
	case .A, .E:
	case .LAST:
	case .D:
	}
}
`,
	}

	test.expect_action_missing(t, &source, POPULATE)
}

// A value the server cannot evaluate gets its own case unless it names an earlier member.
@(test)
populate_switch_cases_enum_unknown_values :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum {
	A = size_of(int),
	B,
	ALIAS = A,
}

f :: proc(k: Kind) {
	swi{*}tch k {
	}
}
`,
	}

	test.expect_action_applied(
		t,
		&source,
		POPULATE,
		`package test

Kind :: enum {
	A = size_of(int),
	B,
	ALIAS = A,
}

f :: proc(k: Kind) {
	switch k {
	case .A:
	case .B:
	}
}
`,
	)
}

// A super enum's member names are qualified by their enum, while its cases are bare names.
@(test)
populate_switch_cases_super_enum_complete :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Sub_One :: enum {
	ONE,
}

Sub_Two :: enum {
	TWO,
}

Super :: union {
	Sub_One,
	Sub_Two,
}

f :: proc(e: Super) {
	swi{*}tch e {
	case .ONE:
	case .TWO:
	}
}
`,
	}

	test.expect_action_missing(t, &source, POPULATE)
}

@(private = "file")
KINDS :: `package kinds

BASE :: 4

Kind :: enum {
	A = BASE,
	B,
	C = 5,
}
`

// Member values name constants of the enum's own package, never locals at the switch.
@(test)
populate_switch_cases_enum_values_in_their_package :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:kinds"

f :: proc(k: kinds.Kind) {
	BASE :: 100
	swi{*}tch k {
	case .A:
	}
}
`,
		packages = {{pkg = "kinds", source = KINDS}},
		collections = {"core" = "test"},
	}

	test.expect_action_applied(
		t,
		&source,
		POPULATE,
		`package test

import "core:kinds"

f :: proc(k: kinds.Kind) {
	BASE :: 100
	switch k {
	case .A:
	case .B:
	}
}
`,
	)
}

// A member whose value is an expression over earlier members shares the case of the member with that value.
@(test)
populate_switch_cases_enum_member_expression :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum {
	A,
	B,
	C,
	LAST = C + 0,
}

f :: proc(k: Kind) {
	#partial swi{*}tch k {
	case .A:
	}
}
`,
	}

	test.expect_action_applied(
		t,
		&source,
		POPULATE,
		`package test

Kind :: enum {
	A,
	B,
	C,
	LAST = C + 0,
}

f :: proc(k: Kind) {
	#partial switch k {
	case .A:
	case .B:
	case .C:
	}
}
`,
	)
}
