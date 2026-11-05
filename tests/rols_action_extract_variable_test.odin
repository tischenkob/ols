package tests

import "core:testing"

import test "src:testing"

EXTRACT_VARIABLE_ACTION :: "Extract variable"

@(test)
action_extract_variable_call_selection :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) -> int {
	return x
}

main :: proc() {
	if {[foo(1)]} > 0 {
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		EXTRACT_VARIABLE_ACTION,
		`package test

foo :: proc(x: int) -> int {
	return x
}

main :: proc() {
	foo2 := foo(1)
	if foo2 > 0 {
		bar()
	}
}
`,
	)
}

@(test)
action_extract_variable_binary_in_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, 2
	y := {[a * b]} + 2
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		EXTRACT_VARIABLE_ACTION,
		`package test

main :: proc() {
	a, b := 1, 2
	value := a * b
	y := value + 2
}
`,
	)
}

@(test)
action_extract_variable_cursor_on_selector :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
}

Player :: struct {
	position: Point,
}

main :: proc() {
	p: Player
	foo(p.posi{*}tion.x)
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (p.position)",
		`package test

Point :: struct {
	x: int,
}

Player :: struct {
	position: Point,
}

main :: proc() {
	p: Player
	position := p.position
	foo(position.x)
}
`,
	)
}

@(test)
action_extract_variable_name_collision :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	value := 1
	x := {[value * 2]} + 3
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		EXTRACT_VARIABLE_ACTION,
		`package test

main :: proc() {
	value := 1
	value2 := value * 2
	x := value2 + 3
}
`,
	)
}

@(test)
action_extract_variable_refused_lhs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
}

main :: proc() {
	p: Point
	{[p.x]} = 5
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}

@(test)
action_extract_variable_refused_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x: {[[]int]}
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}

@(test)
action_extract_variable_refused_loop_condition :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	i, n := 0, 3
	for {[i < n]} {
		i += 1
	}
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}

@(test)
action_extract_variable_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, 2
	y := {[a * b]} + 2
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = false},
	}

	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}

expect_extract_inline_round_trip :: proc(t: ^testing.T, main: string, cursor: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_extract_variable = true, enable_code_action_inline_variable = true},
	}
	test.expect_action_round_trip(t, &source, {EXTRACT_VARIABLE_ACTION, INLINE_VARIABLE_ACTION}, {cursor})
}

expect_no_extract_variable :: proc(t: ^testing.T, main: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_extract_variable = true},
	}
	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}

@(test)
action_extract_variable_round_trip_call :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(
		t,
		`package test

f :: proc(x: int) -> int {
	return x
}

main :: proc() {
	x := 1
	bar({[f(x)]})
}
`,
		"f2 :=",
	)
}

@(test)
action_extract_variable_round_trip_binary_argument :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	a, b := 1, 2
	bar({[a + b]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_index :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(
		t,
		`package test

main :: proc() {
	s := []int{1, 2}
	i := 0
	bar({[s[i]]})
}
`,
		"value :=",
	)
}

@(test)
action_extract_variable_round_trip_selector_chain :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(
		t,
		`package test

Point :: struct {
	x: int,
}

Player :: struct {
	position: Point,
}

main :: proc() {
	p: Player
	bar({[p.position.x]})
}
`,
		"x :=",
	)
}

@(test)
action_extract_variable_round_trip_literal :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	bar({[1]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_string_with_braces :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	bar({["{x}"]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_selection_with_spaces :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(
		t,
		`package test

main :: proc() {
	a, b := 1, 2
	bar({[ a + b ]})
}
`,
		"value :=",
	)
}

@(test)
action_extract_variable_round_trip_ternary :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	c := true
	bar({[c ? 1 : 2]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_paren :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(
		t,
		`package test

main :: proc() {
	a, b := 1, 2
	bar({[(a + b)]})
}
`,
		"value :=",
	)
}

@(test)
action_extract_variable_round_trip_switch_case_body :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(
		t,
		`package test

main :: proc() {
	a, b := 1, 2
	switch a {
	case 1:
		bar({[a + b]})
	}
}
`,
		"value :=",
	)
}

@(test)
action_extract_variable_round_trip_space_indented :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(
		t,
		`package test

main :: proc() {
    a, b := 1, 2
    bar({[a + b]})
}
`,
		"value :=",
	)
}

@(test)
action_extract_variable_round_trip_name_taken :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(
		t,
		`package test

main :: proc() {
	a, b := 1, 2
	value := 0
	bar({[a + b]}, value)
}
`,
		"value2 :=",
	)
}

@(test)
action_extract_variable_round_trip_callee_name_taken_twice :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(
		t,
		`package test

f :: proc(x: int) -> int {
	return x
}

main :: proc() {
	f2 := 1
	bar({[f(f2)]})
}
`,
		"f3 :=",
	)
}

@(test)
action_extract_variable_refused_for_init :: proc(t: ^testing.T) {
	expect_no_extract_variable(t, `package test

main :: proc() {
	n := 3
	for i := {[n - 1]}; i >= 0; i -= 1 {
	}
}
`)
}

@(test)
action_extract_variable_refused_if_init :: proc(t: ^testing.T) {
	expect_no_extract_variable(t, `package test

main :: proc() {
	a, b := 1, 2
	if x := {[a + b]}; x > 0 {
	}
}
`)
}

@(test)
action_extract_variable_refused_do_body :: proc(t: ^testing.T) {
	expect_no_extract_variable(t, `package test

main :: proc() {
	a, b := 1, 2
	if a > 0 do bar({[a + b]})
}
`)
}

@(test)
action_extract_variable_avoids_proc_in_other_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	some_procedure(some_nested_{*}call(1))
}
`,
		files = {
			{
				name = "procs.odin",
				source = `package test

some_procedure :: proc(x: int) -> int { return x }
some_nested_call :: proc(x: int) -> int { return x }
`,
			},
		},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		EXTRACT_VARIABLE_ACTION,
		`package test

main :: proc() {
	some_nested_call2 := some_nested_call(1)
	some_procedure(some_nested_call2)
}
`,
	)
}

@(test)
action_extract_variable_avoids_builtin :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc(s: []int) {
	bar({[len(s)]})
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		EXTRACT_VARIABLE_ACTION,
		`package test

main :: proc(s: []int) {
	len2 := len(s)
	bar(len2)
}
`,
	)
}

@(test)
action_extract_variable_cursor_offers_each_width :: proc(t: ^testing.T) {
	main := `package test

main :: proc() {
	a, b, c := 1, 2, 3
	foo(a + b * c{*})
}
`
	listed := test.Source {
		main = main,
		config = {enable_code_action_extract_variable = true},
	}
	test.expect_action(t, &listed, {"Extract variable (b * c)", "Extract variable (a + b * c)"})

	source := test.Source {
		main = main,
		config = {enable_code_action_extract_variable = true},
	}
	test.expect_action_applied(
		t,
		&source,
		"Extract variable (a + b * c)",
		`package test

main :: proc() {
	a, b, c := 1, 2, 3
	value := a + b * c
	foo(value)
}
`,
	)
}

// The whole initializer is refused, so the one width left keeps the plain title.
@(test)
action_extract_variable_cursor_skips_refused_width :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := 1, 2, 3
	x := a + b * c{*}
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		EXTRACT_VARIABLE_ACTION,
		`package test

main :: proc() {
	a, b, c := 1, 2, 3
	value := b * c
	x := a + value
}
`,
	)
}

@(test)
action_extract_variable_all_whole_initializers :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b
	y := a * b
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := a * b
	x := value
	y := value
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_cursor_on_later_use :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := a * b + 1
	y := {*}a * b + 2
	z := a * b
	use(x, y, z)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 3)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := a * b
	x := value + 1
	y := value + 2
	z := value
	use(x, y, z)
}
`,
	)
}

@(test)
action_extract_variable_all_selection :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {[a * b]} + 1
	y := a * b + 2
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := a * b
	x := value + 1
	y := value + 2
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_dominated_branch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b + 1
	if c {
		y := a * b
		use(y)
	}
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := a * b
	x := value + 1
	if c {
		y := value
		use(y)
	}
	use(x)
}
`,
	)
}

@(test)
action_extract_variable_all_dominated_loop :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b + 1
	for i in 0..<3 {
		use(i, a * b)
	}
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := a * b
	x := value + 1
	for i in 0..<3 {
		use(i, value)
	}
	use(x)
}
`,
	)
}

@(test)
action_extract_variable_all_if_condition_first :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	if {*}a * b > 1 {
		use(a * b)
	}
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := a * b
	if value > 1 {
		use(value)
	}
}
`,
	)
}

@(test)
action_extract_variable_all_skips_case_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b
	switch a * b {
	case a * b:
	}
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := a * b
	x := value
	switch value {
	case a * b:
	}
	use(x)
}
`,
	)
}

@(test)
action_extract_variable_all_avoids_later_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b
	value := 1
	y := a * b
	use(x, y, value)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value2 := a * b
	x := value2
	value := 1
	y := value2
	use(x, y, value)
}
`,
	)
}

@(test)
action_extract_variable_all_field_of_value_over_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {[s.w + 1]}
	take(x)
	y := s.w + 1
	use(y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := s.w + 1
	x := value
	take(x)
	y := value
	use(y)
}
`,
	)
}

@(test)
action_extract_variable_all_locals_over_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b
	take(x)
	y := a * b
	use(y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := a * b
	x := value
	take(x)
	y := value
	use(y)
}
`,
	)
}

@(test)
action_extract_variable_all_slice_element_without_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {[xs[0]]}
	y := xs[0]
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := xs[0]
	x := value
	y := value
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_literal_of_default_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}2
	y := 2
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	value := 2
	x := value
	y := value
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_skips_literal_in_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	q: [2]int
	x := {*}2
	y := 2
	use(q, x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Extract variable (replace all 2)",
		`package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	q: [2]int
	value := 2
	x := value
	y := value
	use(q, x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_refuses_one_occurrence :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 1)")
}

@(test)
action_extract_variable_all_refuses_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}bar(a)
	y := bar(a)
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_conversion :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}int(a)
	y := int(a)
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_call_inside :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a + bar(b)
	y := a + bar(b)
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_write_between :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	u := a
	x := {*}u * b
	u = 2
	y := u * b
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_compound_write_between :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	u := a
	x := {*}u * b
	u += 2
	y := u * b
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_write_in_first_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	u := a
	u = {*}u * b
	y := u * b
	use(y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_write_after_use_in_loop :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	u := a
	x := {*}u * b
	for i in 0..<3 {
		use(i, u * b)
		u = 2
	}
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_address_between :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	u := a
	x := {*}u * b
	q := &u
	y := u * b
	use(x, y, q)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_write_through_pointer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	u := a
	q := &u
	x := {*}u * b
	q^ = 2
	y := u * b
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_nested_procedure :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	u := {*}xs[0]
	h := proc(xs: []int) -> int {
		return xs[0]
	}
	use(u, h)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_defer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b
	defer take(a * b)
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_undominated_branch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	if c {
		use(a * b)
	}
	y := {*}a * b
	use(y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_undominated_and :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	use(c && a * b > 1)
	y := {*}a * b
	use(y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_undominated_ternary :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	use(a * b if c else 1)
	y := {*}a * b
	use(y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_undominated_loop_condition :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	for a * b > 1 {
		break
	}
	y := {*}a * b
	use(y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_inner_block_first :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	{
		use(a * b)
	}
	y := {*}a * b
	use(y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_shadow :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b
	{
		a := 2
		use(a * b)
	}
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_loop_shadow :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}a * b
	for a in 0..<3 {
		use(a * b)
	}
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_call_over_slice :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}xs[0]
	take(1)
	y := xs[0]
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_call_over_pointer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}p.w
	take(1)
	y := p.w
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_alias_write_over_pointer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}p.w
	q := p
	q.w = 3
	y := p.w
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_by_reference_loop_over_slice :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}xs[0]
	for &e in xs {
		e = 1
	}
	y := xs[0]
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_call_over_global :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}G * 2
	take(1)
	y := G * 2
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_two_value_use :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}m[a]
	v, ok := m[a]
	use(x, v, ok)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_write_target :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}xs[a]
	xs[a] = 1
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_slice_of_copy :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	z := [1][3]int{}
	x := {*}z[0]
	use(x, z[0][:])
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_constant_expression :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}MAX_V * 2
	y := MAX_V * 2
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_composite_literal :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}S{w = 1}
	y := S{w = 1}
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_context :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	x := {*}context.user_index
	y := context.user_index
	use(x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_refuses_literal_of_other_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	q: f32 = 2
	x := {*}2
	y := 2
	use(q, x, y)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 3)")
}

@(test)
action_extract_variable_all_refuses_shared_line :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	w: int,
}

G := 3

MAX_V :: 4

bar :: proc(x: int) -> int {
	return x
}

take :: proc(x: int) {
}

f :: proc(a, b: int, c: bool, s: S, p: ^S, xs: []int, m: map[int]int) {
	if c do use({*}a * b)
	use(a * b)
}
`,
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(test)
action_extract_variable_all_needs_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a, b: int) {
	x := {*}a * b
	y := a * b
	use(x, y)
}
`,
	}

	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(private = "file")
expect_no_replace_all :: proc(t: ^testing.T, main: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_extract_variable = true},
	}
	test.expect_action_missing(t, &source, "Extract variable (replace all 2)")
}

@(private = "file")
expect_replace_all :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_extract_variable = true},
	}
	test.expect_action_applied(t, &source, "Extract variable (replace all 2)", expected)
}

@(test)
action_extract_variable_all_refuses_context_typed_ternary :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		`package test

f :: proc(c: bool) {
	x: f32 = {*}c ? 1 : 2
	y: f32 = c ? 1 : 2
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_refuses_context_typed_shift :: proc(t: ^testing.T) {
	expect_no_replace_all(t, `package test

f :: proc(n: uint) {
	x: u64 = 1 <{*}< n
	y: u64 = 1 << n
	use(x, y)
}
`)
}

@(test)
action_extract_variable_all_refuses_auto_cast :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		`package test

f :: proc(n: int) {
	x: f32 = {*}auto_cast n
	y: f32 = auto_cast n
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_refuses_nested_context_typed :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		`package test

f :: proc(n: uint, a: u64) {
	x := a +{*} (1 << n)
	y := a + (1 << n)
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_refuses_comparison_for_other_boolean :: proc(t: ^testing.T) {
	expect_no_replace_all(t, `package test

f :: proc(a, b: int) {
	x: b8 = a <{*} b
	y: b8 = a < b
	use(x, y)
}
`)
}

@(test)
action_extract_variable_all_comparison_in_conditions :: proc(t: ^testing.T) {
	expect_replace_all(
		t,
		`package test

g :: proc() {
}

f :: proc(a, b: int) {
	if a <{*} b {
		g()
	}
	if a < b {
		g()
	}
}
`,
		`package test

g :: proc() {
}

f :: proc(a, b: int) {
	value := a < b
	if value {
		g()
	}
	if value {
		g()
	}
}
`,
	)
}

@(test)
action_extract_variable_all_shift_of_variable :: proc(t: ^testing.T) {
	expect_replace_all(
		t,
		`package test

f :: proc(a: u64, n: uint) {
	x: u64 = a <{*}< n
	y: u64 = a << n
	use(x, y)
}
`,
		`package test

f :: proc(a: u64, n: uint) {
	value := a << n
	x: u64 = value
	y: u64 = value
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_refuses_literal_shifted_for_other_type :: proc(t: ^testing.T) {
	for title in ([]string{"Extract variable", "Extract variable (replace all 2)"}) {
		source := test.Source {
			main = `package test

f :: proc(n: int) {
	x: u64 = {*}1 << n
	y: u64 = 1 << n
	use(x, y)
}
`,
			config = {enable_code_action_extract_variable = true},
		}
		test.expect_action_missing(t, &source, title)
	}
}

@(test)
action_extract_variable_refuses_literal_shift_amount :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(n: int) {
	x := n << {*}2
	use(x)
}
`,
		config = {enable_code_action_extract_variable = true},
	}
	test.expect_action_missing(t, &source, "Extract variable")
}

@(test)
action_extract_variable_all_refuses_plain_write_to_address_taken_local :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		`package test

f :: proc() {
	v := 1
	p := &v
	x := {*}p^ + 1
	v = 5
	y := p^ + 1
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_refuses_plain_write_to_global :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		`package test

G := 1

f :: proc(gp: ^int) {
	x := gp^ +{*} 1
	G = 5
	y := gp^ + 1
	use(x, y)
}
`,
	)
}

@(test)
action_extract_variable_all_keeps_plain_local_write_over_pointer :: proc(t: ^testing.T) {
	expect_replace_all(
		t,
		`package test

f :: proc(p: ^int) {
	k := 1
	x := p^ +{*} 1
	k = 5
	_ = k
	y := p^ + 1
	use(x, y)
}
`,
		`package test

f :: proc(p: ^int) {
	k := 1
	value := p^ + 1
	x := value
	k = 5
	_ = k
	y := value
	use(x, y)
}
`,
	)
}

@(private = "file")
NESTED_TYPES :: `package test

T :: struct {
	f: proc(t: ^T),
}

A :: struct {
	arr: [3]int,
	m:   [2][3]int,
	t:   T,
}

B :: struct {
	s: A,
}
`

@(test)
action_extract_variable_all_refuses_slice_further_up :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		NESTED_TYPES + `
f :: proc() {
	x: B
	a := {[x.s]}.arr[:]
	b := x.s.arr[:]
	a[0] = 1
	use(x, b)
}
`,
	)
}

@(test)
action_extract_variable_all_refuses_slice_through_index_and_paren :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		NESTED_TYPES + `
f :: proc() {
	x: B
	a := ({[x.s]}.m)[0][:]
	b := (x.s.m)[0][:]
	a[0] = 1
	use(x, b)
}
`,
	)
}

@(test)
action_extract_variable_all_refuses_method_further_up :: proc(t: ^testing.T) {
	expect_no_replace_all(t, NESTED_TYPES + `
f :: proc() {
	x: B
	{[x.s]}.t->f()
	x.s.t->f()
}
`)
}

@(test)
action_extract_variable_all_keeps_field_read_further_up :: proc(t: ^testing.T) {
	expect_replace_all(
		t,
		NESTED_TYPES + `
f :: proc() {
	x: B
	a := {[x.s]}.arr[0]
	b := x.s.arr[1]
	use(a, b)
}
`,
		NESTED_TYPES + `
f :: proc() {
	x: B
	s2 := x.s
	a := s2.arr[0]
	b := s2.arr[1]
	use(a, b)
}
`,
	)
}

// A variable cannot stand where the compiler needs a constant.
@(test)
action_extract_variable_all_keeps_literal_in_local_constant :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		`package test

main :: proc() {
	x := {*}2
	K :: 2
	use(x, K)
}
`,
	)
}

@(test)
action_extract_variable_all_keeps_literal_nested_in_local_constant :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		`package test

main :: proc() {
	x := {*}2
	K: int : 1
	A :: K + 2
	use(x, A)
}
`,
	)
}

@(test)
action_extract_variable_all_keeps_literal_in_static_local :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		`package test

main :: proc() {
	x := {*}2
	@(static) s := 2
	use(x, s)
}
`,
	)
}

@(test)
action_extract_variable_all_keeps_literal_in_assert_directive :: proc(t: ^testing.T) {
	expect_no_replace_all(
		t,
		`package test

main :: proc() {
	x := {*}2
	K: int : 1
	#assert(K + 2 > 1)
	use(x)
}
`,
	)
}
