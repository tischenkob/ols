package tests

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

	test.expect_action_applied(t, &source, REMOVE_ELSE_ACTION, `package test

pick :: proc(c: bool) -> int {
	if c {
		return 1
	}
	// fallback
	return 2
}
`)
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

	test.expect_action_applied(t, &source, REMOVE_ELSE_ACTION, `package test

main :: proc() {
	for i in 0 ..< 3 {
		if i == 1 {
			continue
		}
		x := i
		_ = x
	}
}
`)
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

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
	c := true
	x := 1

	_ = x
}
`)
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

	test.expect_action_applied(t, &source, REMOVE_ELSE_ACTION, `package test

main :: proc() {
	for i in 0 ..< 3 {
		if i == 1 {
			break
		}
		foo(i)
	}
}
`)
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

	test.expect_action_applied(t, &source, REMOVE_ELSE_ACTION, `package test

pick :: proc(c: bool) -> int {
    if c {
        return 1
    }
    return 2
}
`)
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

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
	x := 1
	y := 2
	_ = y
	_ = x
}
`)
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

	test.expect_action_chain(t, &source, {UNWRAP_ACTION, UNWRAP_ACTION}, `package test

main :: proc() {
	y := 1
	_ = y
}
`)
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

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
    c := true
    x := 1
    _ = x
}
`)
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

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
	switch x {
	case 1:
		y := 1
		_ = y
	}
}
`)
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
		main = `package test

main :: proc() {
	{*}{
		x := 1
		_ = x
	}
}
`,
		packages = {},
		config = {},
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

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

f :: proc(n: int) {
	for i in 0 ..< n {
		y := i
		_ = y
	}
}
`)
}
