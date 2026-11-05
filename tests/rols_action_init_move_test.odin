package tests

import "core:testing"

import test "src:testing"

@(private = "file")
expect_applied :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_init_move = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

@(private = "file")
expect_missing :: proc(t: ^testing.T, title, main: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_init_move = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
init_move_if :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}, ok := f()
	if ok {
		_ = x
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	if x, ok := f(); ok {
		_ = x
	}
}
`,
	)
}

@(test)
init_move_if_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	if x{*}, ok := f(); ok {
		_ = x
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x, ok := f()
	if ok {
		_ = x
	}
}
`,
	)
}

@(test)
init_move_switch :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into switch init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	n{*} := g()
	switch n {
	case 1:
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	switch n := g(); n {
	case 1:
	}
}
`,
	)
}

@(test)
init_move_switch_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	switch n{*} := g(); n {
	case 1:
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	n := g()
	switch n {
	case 1:
	}
}
`,
	)
}

@(test)
init_move_switch_without_tag :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into switch init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	n{*} := g()
	switch {
	case n > 1:
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	switch n := g(); {
	case n > 1:
	}
}
`,
	)
}

@(test)
init_move_switch_without_tag_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	switch n{*} := g(); {
	case n > 1:
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	n := g()
	switch {
	case n > 1:
	}
}
`,
	)
}

@(test)
init_move_partial_switch :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into switch init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
Kind :: enum {
	A,
	B,
}
kind :: proc() -> Kind {
	return .A
}

main :: proc() {
	n{*} := kind()
	#partial switch n {
	case .A:
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
Kind :: enum {
	A,
	B,
}
kind :: proc() -> Kind {
	return .A
}

main :: proc() {
	#partial switch n := kind(); n {
	case .A:
	}
}
`,
	)
}

@(test)
init_move_partial_switch_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
Kind :: enum {
	A,
	B,
}
kind :: proc() -> Kind {
	return .A
}

main :: proc() {
	#partial switch n{*} := kind(); n {
	case .A:
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
Kind :: enum {
	A,
	B,
}
kind :: proc() -> Kind {
	return .A
}

main :: proc() {
	n := kind()
	#partial switch n {
	case .A:
	}
}
`,
	)
}

@(test)
init_move_for_with_post :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into for init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	i{*} := 0
	for ; i < 3; i += 1 {
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	for i := 0; i < 3; i += 1 {
	}
}
`,
	)
}

@(test)
init_move_for_with_post_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	for i{*} := 0; i < 3; i += 1 {
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	i := 0
	for ; i < 3; i += 1 {
	}
}
`,
	)
}

@(test)
init_move_for_condition_only :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into for init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	i{*} := 0
	for i < 3 {
		i += 1
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	for i := 0; i < 3; {
		i += 1
	}
}
`,
	)
}

@(test)
init_move_for_condition_only_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	for i{*} := 0; i < 3; {
		i += 1
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	i := 0
	for i < 3 {
		i += 1
	}
}
`,
	)
}

@(test)
init_move_labeled :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into for init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	i{*} := 0
	outer: for ; i < 3; i += 1 {
		break outer
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	outer: for i := 0; i < 3; i += 1 {
		break outer
	}
}
`,
	)
}

@(test)
init_move_labeled_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	outer: for i{*} := 0; i < 3; i += 1 {
		break outer
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	i := 0
	outer: for ; i < 3; i += 1 {
		break outer
	}
}
`,
	)
}

@(test)
init_move_out_from_the_condition :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	if x, ok := f(); o{*}k {
		_ = x
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x, ok := f()
	if ok {
		_ = x
	}
}
`,
	)
}

@(test)
init_move_into_a_case_body :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	switch {
	case:
		x{*}, ok := f()
		if ok {
			_ = x
		}
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	switch {
	case:
		if x, ok := f(); ok {
			_ = x
		}
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_use_after :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}, ok := f()
	if ok {
	}
	_ = x
}
`,
	)
}

@(test)
init_move_into_refuses_an_if_with_init :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g()
	if y := x; y > 0 {
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_switch_with_init :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into switch init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g()
	switch y := x; y {
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_for_with_init :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into for init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g()
	for y := x; y > 0; y -= 1 {
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_use_after_a_when_body :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	when true {
		x{*} := g()
		if x > 0 {
		}
	}
	_ = x
}
`,
	)
}

@(test)
init_move_into_refuses_a_statement_that_does_not_use_it :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	b := true
	x{*} := g()
	if b {
	}
	_ = x
}
`,
	)
}

@(test)
init_move_into_refuses_a_literal_in_the_header :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x{*} := Foo{1}
	if x.a > 0 {
	}
}
`,
	)
}

@(test)
init_move_into_refuses_in_for_a_for_header :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into for init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	s: bit_set[0 ..< 8]
	x{*} := 1 in s
	for x {
	}
}
`,
	)
}

@(test)
init_move_into_refuses_for_without_condition :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into for init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g()
	for {
		_ = x
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_directive_on_the_statement :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g()
	#no_bounds_check if x > 0 {
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_trailing_comment :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g() // why
	if x > 0 {
	}
}
`,
	)
}

@(test)
init_move_into_refuses_an_address_that_can_escape :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	p: ^int
	x{*} := g()
	if x > 0 {
		p = &x
	}
	_ = p
}
`,
	)
}

@(test)
init_move_into_refuses_a_constant :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} :: 1
	if x > 0 {
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_static :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	@(static) x{*} := 1
	if x > 0 {
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_type_switch :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into switch init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a{*}: any = 1
	switch v in a {
	case int:
		_ = v
	}
}
`,
	)
}

@(test)
init_move_out_refuses_a_collision_before :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x := 1
	_ = x
	if x{*} := g(); x > 0 {
	}
}
`,
	)
}

@(test)
init_move_out_refuses_a_collision_after :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	if x{*} := g(); x > 0 {
	}
	x := 1
	_ = x
}
`,
	)
}

@(test)
init_move_out_refuses_an_outer_name_read_after :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x := 1
	{
		if x{*} := g(); x > 0 {
		}
		_ = x
	}
}
`,
	)
}

@(test)
init_move_out_refuses_an_else_if :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	b := true
	if b {
	} else if x{*} := g(); x > 0 {
	}
}
`,
	)
}

@(test)
init_move_out_refuses_a_when_body :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	when true {
		if x{*} := g(); x > 0 {
		}
	}
	x := 1
	_ = x
}
`,
	)
}

@(test)
init_move_out_refuses_a_do_body :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	b := true
	if b do if x{*} := g(); x > 0 {
	}
}
`,
	)
}

@(test)
init_move_out_refuses_a_case_on_the_line :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	switch {
	case: if x{*} := g(); x > 0 {
		}
	}
}
`,
	)
}

@(test)
init_move_out_refuses_a_directive :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	#no_bounds_check if x{*} := g(); x > 0 {
	}
}
`,
	)
}

@(test)
init_move_out_refuses_a_named_result :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() -> (x: int) {
	if x{*} := g(); x > 0 {
	}
	return
}
`,
	)
}

@(test)
init_move_out_refuses_a_cursor_in_the_body :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	if x := g(); x > 0 {
		_ = x{*}
	}
}
`,
	)
}

@(test)
init_move_out_refuses_an_assignment :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x: int
	if x{*} = g(); x > 0 {
	}
}
`,
	)
}

@(test)
init_move_into_needs_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}, ok := f()
	if ok {
		_ = x
	}
}
`,
	}
	test.expect_action_missing(t, &source, "Move into if init")
}

@(test)
init_move_out_needs_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	if x{*}, ok := f(); ok {
		_ = x
	}
}
`,
	}
	test.expect_action_missing(t, &source, "Move out of init")
}

@(test)
init_move_into_refuses_or_break_in_a_loop_header :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into for init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}

main :: proc() {
	for {
		x{*} := f() or_break
		for x < 3 {
			break
		}
	}
}
`,
	)
}

@(test)
init_move_for_post_only :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into for init",
		`package test

main :: proc() {
	i{*} := 0
	for ; ; i += 1 {
		break
	}
}
`,
		`package test

main :: proc() {
	for i := 0; ; i += 1 {
		break
	}
}
`,
	)
}

@(test)
init_move_for_post_only_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

main :: proc() {
	for i{*} := 0; ; i += 1 {
		break
	}
}
`,
		`package test

main :: proc() {
	i := 0
	for ; ; i += 1 {
		break
	}
}
`,
	)
}

@(test)
init_move_for_do_body :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into for init",
		`package test

main :: proc() {
	i{*} := 0
	for i < 3 do i += 1
}
`,
		`package test

main :: proc() {
	for i := 0; i < 3; do i += 1
}
`,
	)
}

@(test)
init_move_for_do_body_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

main :: proc() {
	for i{*} := 0; i < 3; do i += 1
}
`,
		`package test

main :: proc() {
	i := 0
	for i < 3 do i += 1
}
`,
	)
}

@(test)
init_move_for_post_and_do_body :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into for init",
		`package test

main :: proc() {
	i{*} := 0
	for ; i < 3; i += 1 do _ = i
}
`,
		`package test

main :: proc() {
	for i := 0; i < 3; i += 1 do _ = i
}
`,
	)
}

@(test)
init_move_for_post_and_do_body_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

main :: proc() {
	for i{*} := 0; i < 3; i += 1 do _ = i
}
`,
		`package test

main :: proc() {
	i := 0
	for ; i < 3; i += 1 do _ = i
}
`,
	)
}

@(test)
init_move_if_do_body :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move into if init",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g()
	if x > 0 do _ = x
}
`,
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	if x := g(); x > 0 do _ = x
}
`,
	)
}

@(test)
init_move_if_do_body_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Move out of init",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	if x{*} := g(); x > 0 do _ = x
}
`,
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x := g()
	if x > 0 do _ = x
}
`,
	)
}

@(test)
init_move_into_refuses_a_comment_line_between :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}

main :: proc() {
	x{*}, ok := f()
	// note
	if ok {
		_ = x
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_blank_line_between :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}

main :: proc() {
	x{*}, ok := f()

	if ok {
		_ = x
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_shadow_after_the_statement :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g()
	if x > 0 {
	}
	{
		x := 2
		_ = x
	}
}
`,
	)
}

@(test)
init_move_into_refuses_an_outer_name_read_above :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x := 1
	{
		_ = x
		x{*} := g()
		if x > 0 {
		}
	}
}
`,
	)
}

@(test)
init_move_into_refuses_a_when_body :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move into if init",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	when true {
		x{*} := g()
		if x > 0 {
		}
	}
}
`,
	)
}

@(test)
init_move_into_refuses_for_with_semicolon_and_no_post :: proc(t: ^testing.T) {
	expect_missing(t, "Move into for init", `package test

main :: proc() {
	i{*} := 0
	for ; i < 3; {
		i += 1
	}
}
`)
}

@(test)
init_move_out_refuses_a_statement_that_does_not_use_it :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	if x{*} := g(); true {
	}
}
`,
	)
}

@(test)
init_move_out_refuses_an_address_that_can_escape :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Move out of init",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	if x{*} := g(); x > 0 {
		p := &x
		_ = p
	}
}
`,
	)
}
