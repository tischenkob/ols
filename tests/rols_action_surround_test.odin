package tests

import "core:testing"

import test "src:testing"

@(private = "file")
expect_applied :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_surround = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

@(private = "file")
expect_missing :: proc(t: ^testing.T, title, main: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_surround = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(private = "file")
expect_needs_flag :: proc(t: ^testing.T, title, main: string) {
	source := test.Source {
		main = main,
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
surround_block :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with block",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{
		g()
	}
	g()
}
`,
	)
}

@(test)
surround_block_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(t, "Surround with block", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
}
`)
}

@(test)
surround_if :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with if",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	if true {
		g()
	}
	g()
}
`,
	)
}

@(test)
surround_if_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(t, "Surround with if", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
}
`)
}

@(test)
surround_for :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with for",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for true {
		g()
	}
	g()
}
`,
	)
}

@(test)
surround_for_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(t, "Surround with for", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
}
`)
}

@(test)
surround_when :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with when",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	when true {
		g()
	}
	g()
}
`,
	)
}

@(test)
surround_when_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(t, "Surround with when", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
}
`)
}

@(test)
surround_defer :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with defer",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	defer {
		g()
	}
	g()
}
`,
	)
}

@(test)
surround_defer_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(t, "Surround with defer", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
}
`)
}

@(test)
surround_no_bounds_check :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with #no_bounds_check",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	#no_bounds_check {
		g()
	}
	g()
}
`,
	)
}

@(test)
surround_no_bounds_check_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(t, "Surround with #no_bounds_check", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g()
}
`)
}

@(test)
surround_selection_touches_statements :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with if",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	g(){[
	g()
	g()]}
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	g()
	if true {
		g()
		g()
	}
	g()
}
`,
	)
}

@(test)
surround_partial_selection :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with if",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	g({[)
	g(]})
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	if true {
		g()
		g()
	}
	g()
}
`,
	)
}

@(test)
surround_keeps_nested_indent_tabs :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with block",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	if c {
		{*}for x in xs {
			g()

			// note
			g()
		}
	}
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	if c {
		{
			for x in xs {
				g()

				// note
				g()
			}
		}
	}
}
`,
	)
}

@(test)
surround_keeps_nested_indent_spaces :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with when",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
    if c {
        {*}if c {
            g()
        }
    }
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
    if c {
        when true {
            if c {
                g()
            }
        }
    }
}
`,
	)
}

@(test)
surround_keeps_trailing_comment :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with if",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g() // note
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	if true {
		g() // note
	}
	g()
}
`,
	)
}

@(test)
surround_case_body :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with if",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	switch 1 {
	case 1:
		{*}g()
	}
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	switch 1 {
	case 1:
		if true {
			g()
		}
	}
}
`,
	)
}

@(test)
surround_used_name_inside_selection :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with block",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{[x := 1
	use(x)]}
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{
		x := 1
		use(x)
	}
	g()
}
`,
	)
}

@(test)
surround_when_keeps_used_name :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with when",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}x := 1
	use(x)
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	when true {
		x := 1
	}
	use(x)
}
`,
	)
}

@(test)
surround_when_keeps_defer :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with when",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}defer g()
	g()
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	when true {
		defer g()
	}
	g()
}
`,
	)
}

@(test)
surround_scope_refuses_used_name :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}x := 1
	use(x)
}
`)
	}
}

@(test)
surround_scope_refuses_constant_used_above :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	use(K)
	{*}K :: 1
}
`)
	}
}

@(test)
surround_scope_refuses_defer :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}defer g()
}
`)
	}
}

@(test)
surround_scope_refuses_context_write :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}context.user_index = 1
}
`)
	}
}

@(test)
surround_scope_refuses_scope_guard :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}guard()
	g()
}

@(deferred_in = g)
guard :: proc() {
}
`)
	}
}

@(test)
surround_scope_refuses_guard_in_when :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}when true {
		defer g()
	}
}
`)
	}
}

@(test)
surround_block_refuses_using :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with block", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	s: It
	{*}using s
}
`)
}

@(test)
surround_for_keeps_inner_branches :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with for",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}for x in xs {
		if x > 0 {
			break
		}
		continue
	}
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for true {
		for x in xs {
			if x > 0 {
				break
			}
			continue
		}
	}
}
`,
	)
}

@(test)
surround_for_keeps_inner_switch_break :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with for",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}switch 1 {
	case 1:
		break
	}
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for true {
		switch 1 {
		case 1:
			break
		}
	}
}
`,
	)
}

@(test)
surround_for_refuses_break :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with for", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for x in xs {
		{*}break
	}
}
`)
}

@(test)
surround_for_refuses_continue :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with for", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for x in xs {
		{*}continue
	}
}
`)
}

@(test)
surround_for_refuses_nested_break :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with for", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for x in xs {
		{*}if c {
			break
		}
	}
}
`)
}

@(test)
surround_for_refuses_continue_through_switch :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with for", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for x in xs {
		switch x {
		case 1:
			{*}continue
		}
	}
}
`)
}

@(test)
surround_for_refuses_switch_break :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with for", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	switch 1 {
	case 1:
		{*}break
	}
}
`)
}

@(test)
surround_for_refuses_labeled_break :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with for", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	outer: for x in xs {
		{*}break outer
	}
}
`)
}

@(test)
surround_for_refuses_or_break :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with for", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for x in xs {
		{*}ok() or_break
	}
}
`)
}

@(test)
surround_if_keeps_outer_break :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with if",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for x in xs {
		{*}break
	}
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for x in xs {
		if true {
			break
		}
	}
}
`,
	)
}

@(test)
surround_defer_refuses_return :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with defer", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}return
}
`)
}

@(test)
surround_defer_refuses_nested_return :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with defer", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}if c {
		return
	}
}
`)
}

@(test)
surround_defer_refuses_or_return :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with defer", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}ok() or_return
}
`)
}

@(test)
surround_defer_refuses_name :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with defer", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}x := 1
}
`)
}

@(test)
surround_defer_refuses_constant :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with defer", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}K :: 1
}
`)
}

@(test)
surround_defer_refuses_break :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with defer", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	for x in xs {
		{*}break
	}
}
`)
}

@(test)
surround_defer_refuses_inner_labeled_break :: proc(t: ^testing.T) {
	expect_missing(t, "Surround with defer", `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}if c {
		inner: for x in xs {
			break inner
		}
	}
}
`)
}

@(test)
surround_defer_keeps_nested_scope :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with defer",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}if c {
		x := 1
		use(x)
	}
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	defer {
		if c {
			x := 1
			use(x)
		}
	}
}
`,
	)
}

@(test)
surround_return_in_nested_procedure :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with defer",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}use(proc() {
		return
	})
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	defer {
		use(proc() {
			return
		})
	}
}
`,
	)
}

@(test)
surround_block_keeps_final_return :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with block",
		`package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	{*}return 1
}
`,
		`package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	{
		return 1
	}
}
`,
	)
}

@(test)
surround_when_keeps_final_return :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with when",
		`package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	{*}return 1
}
`,
		`package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	when true {
		return 1
	}
}
`,
	)
}

@(test)
surround_no_bounds_check_keeps_final_return :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with #no_bounds_check",
		`package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	{*}return 1
}
`,
		`package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	#no_bounds_check {
		return 1
	}
}
`,
	)
}

@(test)
surround_if_keeps_early_statement :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with if",
		`package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	{*}g()
	return 1
}
`,
		`package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	if true {
		g()
	}
	return 1
}
`,
	)
}

@(test)
surround_refuses_final_return :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with if", "Surround with for", "Surround with defer"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	{*}return 1
}
`)
	}
}

@(test)
surround_refuses_final_if_else :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with if", "Surround with for", "Surround with defer"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	{*}if c {
		return 1
	} else {
		return 2
	}
}
`)
	}
}

@(test)
surround_refuses_final_loop :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with if", "Surround with for", "Surround with defer"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	{*}for {
		return 1
	}
}
`)
	}
}

@(test)
surround_refuses_final_switch :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with if", "Surround with for", "Surround with defer"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

h :: proc(c: bool) -> int {
	{*}switch c {
	case true:
		return 1
	case:
		return 2
	}
}
`)
	}
}

@(test)
surround_refuses_fallthrough :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with if", "Surround with for", "Surround with defer"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	switch 1 {
	case 1:
		{*}fallthrough
	case 2:
	}
}
`)
	}
}

@(test)
surround_block_keeps_fallthrough :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with block",
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	switch 1 {
	case 1:
		{*}fallthrough
	case 2:
	}
}
`,
		`package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	switch 1 {
	case 1:
		{
			fallthrough
		}
	case 2:
	}
}
`,
	)
}

@(test)
surround_refuses_shared_line :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	g(); {*}g()
}
`)
	}
}

@(test)
surround_refuses_do_body :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	if c do {*}g()
}
`)
	}
}

@(test)
surround_refuses_brace_line :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	if c { {*}g() }
}
`)
	}
}

@(test)
surround_refuses_case_line :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	switch 1 {
	case 1: {*}g()
	}
}
`)
	}
}

@(test)
surround_refuses_attribute_above :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	@(static)
	{*}n := 0
}
`)
	}
}

@(test)
surround_refuses_label_above :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	lbl:
	{*}for x in xs {
		break lbl
	}
}
`)
	}
}

@(test)
surround_refuses_label_on_line :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	lbl: {*}for x in xs {
		break lbl
	}
}
`)
	}
}

@(test)
surround_refuses_block_comment_after :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	{*}g() /* a
	b */
}
`)
	}
}

@(test)
surround_refuses_blank_line :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	g()

{*}
	g()
}
`)
	}
}

@(test)
surround_refuses_outside_procedure :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, `package test

g :: proc() {
}

f :: proc(c: bool, xs: []int) {
	g()
}

{*}x :: 1

y :: proc() {
}
`)
	}
}

@(test)
surround_refuses_multiline_string :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, "package test\n\nf :: proc() {\n\t{*}x := `a\n  b`\n\t_ = x\n}\n")
	}
}

@(test)
surround_refuses_multiline_string_in_nested_procedure :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(
			t,
			title,
			"package test\n\nf :: proc() {\n\t{*}use(proc() {\n\t\tx := `a\n  b`\n\t\t_ = x\n\t})\n}\n",
		)
	}
}

@(test)
surround_refuses_multiline_struct_tag :: proc(t: ^testing.T) {
	for title in ([]string{"Surround with block", "Surround with if", "Surround with for", "Surround with when", "Surround with defer", "Surround with #no_bounds_check"}) {
		expect_missing(t, title, "package test\n\nf :: proc() {\n\t{*}use(struct {\n\t\ta: int `x\n  y`,\n\t}{})\n}\n")
	}
}

@(test)
surround_keeps_single_line_string_in_nested_procedure :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Surround with block",
		"package test\n\nf :: proc() {\n\t{*}use(proc() {\n\t\tx := `a`\n\t\t_ = x\n\t})\n}\n",
		"package test\n\nf :: proc() {\n\t{\n\t\tuse(proc() {\n\t\t\tx := `a`\n\t\t\t_ = x\n\t\t})\n\t}\n}\n",
	)
}
