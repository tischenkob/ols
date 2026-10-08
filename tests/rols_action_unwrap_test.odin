package tests

import "core:strings"
import "core:testing"

import test "src:testing"

UNWRAP_ACTION :: "Unwrap block"
REMOVE_ELSE_ACTION :: "Remove redundant else"

@(test)
action_remove_else_after_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	{*}if c {
		return 1
	} else {
		// fallback
		return 2
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		REMOVE_ELSE_ACTION,
		`package test

pick :: proc(c: bool) -> int {
	if c {
		return 1
	}
	// fallback
	return 2
}
`,
	)
}

@(test)
action_remove_else_after_continue :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	for i in 0 ..< 3 {
		{*}if i == 1 {
			continue
		} else {
			x := i
			_ = x
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		REMOVE_ELSE_ACTION,
		`package test

main :: proc() {
	for i in 0 ..< 3 {
		if i == 1 {
			continue
		}
		x := i
		_ = x
	}
}
`,
	)
}

@(test)
action_remove_else_refused_else_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c, d: bool) -> int {
	{*}if c {
		return 1
	} else if d {
		return 2
	}
	return 3
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_remove_else_refused_without_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	c := true
	{*}if c {
		x = 1
	} else {
		x = 2
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_unwrap_bare_block :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	{*}{
		x := 1
		_ = x
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
	x := 1
	_ = x
}
`)
}

@(test)
action_unwrap_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	c := true
	{*}if c {
		x := 1

		_ = x
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		UNWRAP_ACTION,
		`package test

main :: proc() {
	c := true
	x := 1

	_ = x
}
`,
	)
}

@(test)
action_unwrap_not_offered_on_for :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	n := 0
	{*}for n < 3 {
		n += 1
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_unwrap_refused_if_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	c := true
	{*}if c {
		x = 1
	} else {
		x = 2
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_remove_else_after_break :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	for i in 0 ..< 3 {
		{*}if i == 1 {
			break
		} else {
			foo(i)
		}
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		REMOVE_ELSE_ACTION,
		`package test

main :: proc() {
	for i in 0 ..< 3 {
		if i == 1 {
			break
		}
		foo(i)
	}
}
`,
	)
}

@(test)
action_remove_else_space_indent :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
    {*}if c {
        return 1
    } else {
        return 2
    }
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		REMOVE_ELSE_ACTION,
		`package test

pick :: proc(c: bool) -> int {
    if c {
        return 1
    }
    return 2
}
`,
	)
}

@(test)
action_remove_else_refused_after_panic :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	{*}if c {
		panic("no")
	} else {
		return 2
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_remove_else_refused_nested_if_returns :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c, d: bool) -> int {
	{*}if c {
		if d {
			return 1
		}
	} else {
		return 2
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_unwrap_refused_shadowing_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 1
	{*}{
		x := 2
		_ = x
	}
	_ = x
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_unwrap_refused_declaration_below :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	{*}{
		a, x := 1, 2
		_ = a + x
	}
	x := 3
	_ = x
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_unwrap_fresh_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 1
	{*}{
		y := 2
		_ = y
	}
	_ = x
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		UNWRAP_ACTION,
		`package test

main :: proc() {
	x := 1
	y := 2
	_ = y
	_ = x
}
`,
	)
}

@(test)
action_unwrap_nested_blocks_twice :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	{*}{
		{
			y := 1
			_ = y
		}
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_chain(
		t,
		&source,
		{UNWRAP_ACTION, UNWRAP_ACTION},
		`package test

main :: proc() {
	y := 1
	_ = y
}
`,
	)
}

@(test)
action_unwrap_empty_block :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	{*}{
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
}
`)
}

@(test)
action_unwrap_comment_only_block :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	{*}{
		// note
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
	// note
}
`)
}

@(test)
action_unwrap_space_indent :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
    c := true
    {*}if c {
        x := 1
        _ = x
    }
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		UNWRAP_ACTION,
		`package test

main :: proc() {
    c := true
    x := 1
    _ = x
}
`,
	)
}

@(test)
action_unwrap_block_in_case_clause :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	switch x {
	case 1:
		{*}{
			y := 1
			_ = y
		}
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		UNWRAP_ACTION,
		`package test

main :: proc() {
	switch x {
	case 1:
		y := 1
		_ = y
	}
}
`,
	)
}

@(test)
action_unwrap_refused_if_with_init :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	{*}if x := foo(); x > 0 {
		bar(x)
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_unwrap_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	{*}{
		x := 1
		_ = x
	}
}
`,
		packages = {},
		config   = {},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

// Corpus: tina src/extensions/http/server/body.odin:841, see docs/corpus-validation.md.
@(test)
action_unwrap_not_offered_on_range_loop_using_its_variable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(buf: []int) {
	{*}for i in 0 ..< len(buf) {
		buf[i] = i
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

// Corpus: Skald examples/13_stopwatch/main.odin:37, see docs/corpus-validation.md.
@(test)
action_unwrap_not_offered_when_body_returns_before_statements :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(running: bool) -> int {
	{*}if running {
		return 1
	}
	return 2
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_remove_else_refused_inner_else_if_chain :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc(a, b: bool) {
	x := 0
	if a {
		return
	} else {*}if b {
		return
	} else {
		x = 1
	}
	_ = x
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_remove_else_refused_before_more_statements :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	{*}if c {
		return 1
	} else {
		return 2
	}
	return 0
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_remove_else_refused_labeled_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	label: {*}if c {
		return 1
	} else {
		return 2
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_remove_else_refused_in_when_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	when true {
		{*}if c {
			return 1
		} else {
			return 2
		}
	}
	return 0
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_remove_else_refused_redeclared_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	x := 1
	_ = x
	{*}if c {
		return 1
	} else {
		x := 2
		return x
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_remove_else_refused_comment_before_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	{*}if c {
		return 1
	} /* keep me */ else {
		return 2
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_unwrap_not_offered_on_blank_range_loop :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(n: int) -> int {
	s := 0
	{*}for _ in 0 ..< n {
		s += 1
	}
	return s
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_unwrap_not_offered_on_c_style_loop :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(n: int) -> int {
	s := 0
	{*}for k := 0; k < n; k += 1 {
		s += 1
	}
	return s
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_unwrap_bare_block_inside_loop :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(n: int) {
	for i in 0 ..< n {
		{*}{
			y := i
			_ = y
		}
	}
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		UNWRAP_ACTION,
		`package test

f :: proc(n: int) {
	for i in 0 ..< n {
		y := i
		_ = y
	}
}
`,
	)
}

// A panic, an exit call or an if whose branches all return ends the body, so `return 2` would become unreachable.
@(test)
action_unwrap_not_offered_when_body_ends_flow_before_statements :: proc(t: ^testing.T) {
	bodies := []string{"panic(\"no\")", "os.exit(1)", "if d {\n\t\t\treturn 1\n\t\t} else {\n\t\t\treturn 0\n\t\t}"}
	for body in bodies {
		source := test.Source {
			main = strings.concatenate(
				{`package test

f :: proc(c, d: bool) -> int {
	{*}if c {
		`, body, `
	}
	return 2
}
`},
				context.temp_allocator,
			),
			config = {enable_code_action_unwrap = true},
		}

		test.expect_action_missing(t, &source, UNWRAP_ACTION)
	}
}

@(test)
action_remove_else_before_more_statements :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	x := 0
	{*}if c {
		return 1
	} else {
		y := 2
		x = y
	}
	return x
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		REMOVE_ELSE_ACTION,
		`package test

pick :: proc(c: bool) -> int {
	x := 0
	if c {
		return 1
	}
	y := 2
	x = y
	return x
}
`,
	)
}

// After the if, `y := 3` would redeclare the unwrapped y, and the deferred g would run after `return x`.
@(test)
action_remove_else_refused_before_colliding_or_deferred_statements :: proc(t: ^testing.T) {
	for else_body in ([]string{"y := 2\n\t\tx = y\n\t}\n\ty := 3\n\tx += y", "defer g()\n\t\tx = 2\n\t}\n\tx += 1"}) {
		source := test.Source {
			main = strings.concatenate(
				{
					`package test

g :: proc() {}

pick :: proc(c: bool) -> int {
	x := 0
	{*}if c {
		return 1
	} else {
		`,
					else_body,
					`
	return x
}
`,
				},
				context.temp_allocator,
			),
			config = {enable_code_action_unwrap = true},
		}

		test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
	}
}

@(test)
action_unwrap_else_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(c, d: bool) -> int {
	x := 0
	if c {
		x = 1
	} else {*}if d {
		x = 2
	}
	return x
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		UNWRAP_ACTION,
		`package test

f :: proc(c, d: bool) -> int {
	x := 0
	if c {
		x = 1
	} else {
		x = 2
	}
	return x
}
`,
	)
}

// A procedure named `exit` that returns does not end the flow.
@(test)
action_unwrap_resolved_exit_that_returns :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "lib"

x :: proc() {}

f :: proc(c: bool) {
	{*}if c {
		lib.exit()
	}
	x()
}
`,
		packages = {{pkg = "lib", source = `package lib

exit :: proc() {}
`}},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(
		t,
		&source,
		UNWRAP_ACTION,
		`package test

import "lib"

x :: proc() {}

f :: proc(c: bool) {
	lib.exit()
	x()
}
`,
	)
}

@(test)
action_unwrap_not_offered_after_diverging_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "lib"

x :: proc() {}

f :: proc(c: bool) {
	{*}if c {
		lib.stop()
	}
	x()
}
`,
		packages = {{pkg = "lib", source = `package lib

stop :: proc() -> ! {
	for {}
}
`}},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_unwrap_not_offered_on_else_if_with_init_or_else :: proc(t: ^testing.T) {
	for chain in ([]string{"} else {*}if y := 2; d {\n\t\tx = y\n\t}", "} else {*}if d {\n\t\tx = 2\n\t} else {\n\t\tx = 3\n\t}"}) {
		source := test.Source {
			main = strings.concatenate(
				{`package test

f :: proc(c, d: bool) -> int {
	x := 0
	if c {
		x = 1
	`, chain, `
	return x
}
`},
				context.temp_allocator,
			),
			config = {enable_code_action_unwrap = true},
		}

		test.expect_action_missing(t, &source, UNWRAP_ACTION)
	}
}

// A solved polymorphic procedure keeps its `-> !`.
@(test)
action_unwrap_not_offered_after_generic_diverging_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

stop :: proc(x: $T) -> ! {
	for {}
}

x :: proc() {}

f :: proc(c: bool) {
	{*}if c {
		stop(1)
	}
	x()
}
`,
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}
