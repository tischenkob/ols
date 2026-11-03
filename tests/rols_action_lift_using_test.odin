package tests

import "core:strings"
import "core:testing"

import test "src:testing"

LIFT_INNER :: "Lift using a.mid.inner"

LIFT_PRELUDE :: `package test

Inner :: struct {
	x, y: int,
}

Mid :: struct {
	inner: Inner,
	ptr:   ^Inner,
	vals:  [3]Inner,
	count: int,
}

Outer :: struct {
	mid: Mid,
}

Base :: struct {
	base_x: int,
}

Derived :: struct {
	using base: Base,
	own:        int,
}

Padded :: struct {
	_:     [4]u8,
	value: int,
}

Kind :: enum {
	A,
	B,
}

CONSTANT :: Inner{}

g_outer: Outer

`

LIFT_TAG :: "#+feature using-stmt\n"

expect_lift_text :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_lift_using = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

expect_lift :: proc(t: ^testing.T, title, body, expected: string) {
	expect_lift_text(
		t,
		title,
		strings.concatenate({LIFT_PRELUDE, body}, context.temp_allocator),
		strings.concatenate({LIFT_TAG, LIFT_PRELUDE, expected}, context.temp_allocator),
	)
}

expect_no_lift :: proc(t: ^testing.T, title, body: string) {
	source := test.Source {
		main = strings.concatenate({LIFT_PRELUDE, body}, context.temp_allocator),
		config = {enable_code_action_lift_using = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
lift_using_basic :: proc(t: ^testing.T) {
	expect_lift(
		t,
		LIFT_INNER,
		`main :: proc() {
	a: Outer
	foo(a.mid.inner.{*}x)
	bar(a.mid.inner.y)
}
`,
		`main :: proc() {
	a: Outer
	using a.mid.inner
	foo(x)
	bar(y)
}
`,
	)
}

@(test)
lift_using_goes_before_a_use_above_the_cursor :: proc(t: ^testing.T) {
	expect_lift(
		t,
		LIFT_INNER,
		`main :: proc() {
	a: Outer
	start()
	foo(a.mid.inner.x)
	bar(a.mid.inner.{*}y)
}
`,
		`main :: proc() {
	a: Outer
	start()
	using a.mid.inner
	foo(x)
	bar(y)
}
`,
	)
}

@(test)
lift_using_rewrites_nested_blocks :: proc(t: ^testing.T) {
	expect_lift(
		t,
		LIFT_INNER,
		`main :: proc() {
	a: Outer
	foo(a.mid.inner.{*}x)
	if ok() {
		for i := 0; i < a.mid.inner.y; i += 1 {
			bar(a.mid.inner.x)
		}
	}
}
`,
		`main :: proc() {
	a: Outer
	using a.mid.inner
	foo(x)
	if ok() {
		for i := 0; i < y; i += 1 {
			bar(x)
		}
	}
}
`,
	)
}

@(test)
lift_using_stays_in_the_block_of_the_cursor :: proc(t: ^testing.T) {
	expect_lift(
		t,
		LIFT_INNER,
		`main :: proc() {
	a: Outer
	foo(a.mid.inner.x)
	if ok() {
		bar(a.mid.inner.{*}y)
	}
	baz(a.mid.inner.y)
}
`,
		`main :: proc() {
	a: Outer
	foo(a.mid.inner.x)
	if ok() {
		using a.mid.inner
		bar(y)
	}
	baz(a.mid.inner.y)
}
`,
	)
}

@(test)
lift_using_case_body :: proc(t: ^testing.T) {
	expect_lift(
		t,
		LIFT_INNER,
		`main :: proc() {
	a: Outer
	switch kind() {
	case .A:
		foo(a.mid.inner.{*}x)
	case .B:
		bar(a.mid.inner.y)
	}
}
`,
		`main :: proc() {
	a: Outer
	switch kind() {
	case .A:
		using a.mid.inner
		foo(x)
	case .B:
		bar(a.mid.inner.y)
	}
}
`,
	)
}

@(test)
lift_using_single_identifier :: proc(t: ^testing.T) {
	expect_lift(
		t,
		"Lift using v",
		`main :: proc() {
	v: Inner
	foo(v.{*}x)
	bar(v.y)
}
`,
		`main :: proc() {
	v: Inner
	using v
	foo(x)
	bar(y)
}
`,
	)
}

@(test)
lift_using_parameter_through_pointer :: proc(t: ^testing.T) {
	expect_lift(
		t,
		"Lift using a.mid.ptr",
		`main :: proc(a: ^Outer) {
	foo(a.mid.ptr.{*}x)
	bar(a.mid.ptr.y)
}
`,
		`main :: proc(a: ^Outer) {
	using a.mid.ptr
	foo(x)
	bar(y)
}
`,
	)
}

@(test)
lift_using_embedded_field :: proc(t: ^testing.T) {
	expect_lift(
		t,
		"Lift using d",
		`main :: proc() {
	d: Derived
	foo(d.{*}base_x)
	bar(d.own)
}
`,
		`main :: proc() {
	d: Derived
	using d
	foo(base_x)
	bar(own)
}
`,
	)
}

@(test)
lift_using_ignores_blank_field :: proc(t: ^testing.T) {
	expect_lift(
		t,
		"Lift using p",
		`main :: proc() {
	p: Padded
	_ = foo(p.{*}value)
}
`,
		`main :: proc() {
	p: Padded
	using p
	_ = foo(value)
}
`,
	)
}

@(test)
lift_using_writes_and_address :: proc(t: ^testing.T) {
	expect_lift(
		t,
		LIFT_INNER,
		`main :: proc() {
	a: Outer
	a.mid.inner.{*}x = 1
	p := &a.mid.inner.y
	foo(p)
}
`,
		`main :: proc() {
	a: Outer
	using a.mid.inner
	x = 1
	p := &y
	foo(p)
}
`,
	)
}

@(test)
lift_using_global_root_skips_nested_procedure :: proc(t: ^testing.T) {
	expect_lift(
		t,
		"Lift using g_outer.mid.inner",
		`main :: proc() {
	foo(g_outer.mid.inner.{*}x)
	f := proc() {
		bar(g_outer.mid.inner.y)
	}
	f()
}
`,
		`main :: proc() {
	using g_outer.mid.inner
	foo(x)
	f := proc() {
		bar(g_outer.mid.inner.y)
	}
	f()
}
`,
	)
}

@(test)
lift_using_leaves_a_shadowed_root :: proc(t: ^testing.T) {
	expect_lift(
		t,
		LIFT_INNER,
		`main :: proc() {
	a: Outer
	foo(a.mid.inner.{*}x)
	if ok() {
		a := other()
		bar(a.mid.inner.y)
	}
}
`,
		`main :: proc() {
	a: Outer
	using a.mid.inner
	foo(x)
	if ok() {
		a := other()
		bar(a.mid.inner.y)
	}
}
`,
	)
}

@(test)
lift_using_leaves_the_whole_path_and_arrow_calls :: proc(t: ^testing.T) {
	expect_lift(
		t,
		LIFT_INNER,
		`main :: proc() {
	a: Outer
	foo(a.mid.inner.{*}x)
	bar(a.mid.inner)
	a.mid.inner->run()
}
`,
		`main :: proc() {
	a: Outer
	using a.mid.inner
	foo(x)
	bar(a.mid.inner)
	a.mid.inner->run()
}
`,
	)
}

@(test)
lift_using_cursor_on_middle_segment :: proc(t: ^testing.T) {
	expect_lift(
		t,
		"Lift using a.mid",
		`main :: proc() {
	a: Outer
	foo(a.{*}mid.inner.x)
	bar(a.mid.count)
}
`,
		`main :: proc() {
	a: Outer
	using a.mid
	foo(inner.x)
	bar(count)
}
`,
	)
}

@(test)
lift_using_selection :: proc(t: ^testing.T) {
	expect_lift(
		t,
		"Lift using a.mid",
		`main :: proc() {
	a: Outer
	foo({[a.mid]}.count)
}
`,
		`main :: proc() {
	a: Outer
	using a.mid
	foo(count)
}
`,
	)
}

@(test)
lift_using_tag_after_existing_tags :: proc(t: ^testing.T) {
	expect_lift_text(
		t,
		"Lift using v",
		`#+private

package test

Inner :: struct {
	x: int,
}

main :: proc() {
	v: Inner
	foo(v.{*}x)
}
`,
		`#+private
#+feature using-stmt

package test

Inner :: struct {
	x: int,
}

main :: proc() {
	v: Inner
	using v
	foo(x)
}
`,
	)
}

@(test)
lift_using_tag_before_package_docs :: proc(t: ^testing.T) {
	expect_lift_text(
		t,
		"Lift using v",
		`// Docs.
package test

Inner :: struct {
	x: int,
}

main :: proc() {
	v: Inner
	foo(v.{*}x)
}
`,
		`#+feature using-stmt
// Docs.
package test

Inner :: struct {
	x: int,
}

main :: proc() {
	v: Inner
	using v
	foo(x)
}
`,
	)
}

@(test)
lift_using_tag_not_duplicated :: proc(t: ^testing.T) {
	expect_lift_text(
		t,
		"Lift using v",
		`#+feature dynamic-literals, using-stmt
package test

Inner :: struct {
	x: int,
}

main :: proc() {
	v: Inner
	foo(v.{*}x)
}
`,
		`#+feature dynamic-literals, using-stmt
package test

Inner :: struct {
	x: int,
}

main :: proc() {
	v: Inner
	using v
	foo(x)
}
`,
	)
}

@(test)
lift_using_keeps_struct_literal_and_argument_names :: proc(t: ^testing.T) {
	expect_lift(
		t,
		"Lift using a.mid",
		`main :: proc() {
	a: Outer
	m := Mid{count = a.mid.{*}count}
	foo(m, count = a.mid.count)
}
`,
		`main :: proc() {
	a: Outer
	using a.mid
	m := Mid{count = count}
	foo(m, count = count)
}
`,
	)
}

@(test)
lift_using_goes_before_a_use_below_the_cursor :: proc(t: ^testing.T) {
	expect_lift(
		t,
		"Lift using v",
		`main :: proc() {
	v: Inner
	bar({*}v)
	start()
	foo(v.y)
}
`,
		`main :: proc() {
	v: Inner
	bar(v)
	start()
	using v
	foo(y)
}
`,
	)
}

@(test)
lift_using_refuses_local_between_cursor_and_first_use :: proc(t: ^testing.T) {
	expect_no_lift(t, "Lift using v", "main :: proc() {\n\tv: Inner\n\tbar({*}v)\n\tx := 1\n\tfoo(v.y)\n}\n")
}

@(test)
lift_using_refuses_using_between_cursor_and_first_use :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		"Lift using v",
		"main :: proc() {\n\tv: Inner\n\to: Inner\n\tbar({*}v)\n\tusing o\n\tfoo(v.y)\n}\n",
	)
}

@(test)
lift_using_refuses_qualified_offset_of :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		LIFT_INNER,
		"main :: proc() {\n\ta: Outer\n\tfoo(a.mid.inner.{*}x)\n\tn := builtin.offset_of(a.mid.inner.y)\n}\n",
	)
}

@(test)
lift_using_refuses_root_declared_in_if_header :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		"Lift using a.mid",
		"main :: proc() {\n\tif a := get(); a.mid.{*}count > 0 {\n\t\tfoo(a.mid.count)\n\t}\n}\n\nget :: proc() -> Outer {\n\treturn {}\n}\n",
	)
}

@(test)
lift_using_refuses_root_declared_in_for_header :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		"Lift using a.mid",
		"main :: proc() {\n\tfor a := get(); a.mid.{*}count > 0; a.mid.count -= 1 {\n\t}\n}\n\nget :: proc() -> Outer {\n\treturn {}\n}\n",
	)
}

@(test)
lift_using_refuses_using_in_nested_block :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		LIFT_INNER,
		"main :: proc() {\n\to: Inner\n\ta: Outer\n\tfoo(a.mid.inner.{*}x)\n\tif ok() {\n\t\tusing o\n\t\tbar(a.mid.inner.y)\n\t}\n}\n",
	)
}

@(test)
lift_using_refuses_using_in_same_block :: proc(t: ^testing.T) {
	expect_no_lift(t, LIFT_INNER, "main :: proc() {\n\to: Inner\n\ta: Outer\n\tfoo(a.mid.inner.{*}x)\n\tusing o\n}\n")
}

@(test)
lift_using_refuses_using_declaration_in_range :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		LIFT_INNER,
		"main :: proc() {\n\ta: Outer\n\tfoo(a.mid.inner.{*}x)\n\tusing o := make_inner()\n}\n",
	)
}

@(test)
lift_using_refuses_label_on_its_own_line :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		"Lift using a.mid",
		"main :: proc() {\n\ta: Outer\n\touter:\n\tfor i := 0; i < a.mid.{*}count; i += 1 {\n\t}\n}\n",
	)
}

@(test)
lift_using_refuses_attribute_on_its_own_line :: proc(t: ^testing.T) {
	expect_no_lift(t, "Lift using a.mid", "main :: proc() {\n\ta: Outer\n\t@(static)\n\tn := a.mid.{*}count\n}\n")
}

@(test)
lift_using_refuses_directive_on_its_own_line :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		"Lift using a.mid",
		"main :: proc() {\n\ta: Outer\n\t#no_bounds_check\n\tfor i := 0; i < a.mid.{*}count; i += 1 {\n\t}\n}\n",
	)
}

@(test)
lift_using_refuses_offset_of :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		LIFT_INNER,
		"main :: proc() {\n\ta: Outer\n\tfoo(a.mid.inner.{*}x)\n\tn := offset_of(a.mid.inner.y)\n}\n",
	)
}

@(test)
lift_using_refuses_array_literal_key_named_like_a_field :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		"Lift using a.mid",
		"main :: proc() {\n\ta: Outer\n\tfoo(a.mid.{*}vals)\n\tarr := [3]int{count = 5}\n}\n",
	)
}

@(test)
lift_using_refuses_untyped_literal_key_named_like_a_field :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		"Lift using a.mid",
		"main :: proc() {\n\ta: Outer\n\tfoo(a.mid.{*}vals)\n\tb := Outer{mid = {count = 5}}\n}\n",
	)
}

@(test)
lift_using_flag_off :: proc(t: ^testing.T) {
	source := test.Source {
		main = strings.concatenate(
			{LIFT_PRELUDE, "main :: proc() {\n\ta: Outer\n\tfoo(a.mid.inner.{*}x)\n}\n"},
			context.temp_allocator,
		),
		config = {enable_code_action_lift_using = false},
	}
	test.expect_action_missing(t, &source, LIFT_INNER)
}

@(test)
lift_using_refuses_index_in_path :: proc(t: ^testing.T) {
	expect_no_lift(t, "Lift using a.mid.vals[0]", "main :: proc() {\n\ta: Outer\n\tfoo(a.mid.vals[0].{*}x)\n}\n")
}

@(test)
lift_using_refuses_call_in_path :: proc(t: ^testing.T) {
	expect_no_lift(t, "Lift using get()", "main :: proc() {\n\tfoo(get().{*}x)\n}\n")
}

@(test)
lift_using_refuses_enum :: proc(t: ^testing.T) {
	expect_no_lift(t, "Lift using Kind", "main :: proc() {\n\tfoo(Kind.{*}A)\n}\n")
}

@(test)
lift_using_refuses_constant :: proc(t: ^testing.T) {
	expect_no_lift(t, "Lift using CONSTANT", "main :: proc() {\n\tfoo(CONSTANT.{*}x)\n}\n")
}

@(test)
lift_using_refuses_package_root :: proc(t: ^testing.T) {
	expect_no_lift(t, "Lift using fmt", "main :: proc() {\n\tfmt.{*}println()\n}\n")
}

@(test)
lift_using_refuses_array_swizzle :: proc(t: ^testing.T) {
	expect_no_lift(t, "Lift using b", "main :: proc() {\n\tb: [3]int\n\tfoo(b.{*}x)\n}\n")
}

@(test)
lift_using_refuses_pointer_to_pointer :: proc(t: ^testing.T) {
	expect_no_lift(t, "Lift using pp", "main :: proc() {\n\tpp: ^^Inner\n\tfoo(pp.{*}x)\n}\n")
}

@(test)
lift_using_refuses_bare_field_name_in_range :: proc(t: ^testing.T) {
	expect_no_lift(t, LIFT_INNER, "main :: proc() {\n\ta: Outer\n\tfoo(a.mid.inner.{*}y)\n\tbar(x)\n}\n")
}

@(test)
lift_using_refuses_parameter_collision :: proc(t: ^testing.T) {
	expect_no_lift(t, LIFT_INNER, "main :: proc(x: int) {\n\ta: Outer\n\tfoo(a.mid.inner.{*}y)\n}\n")
}

@(test)
lift_using_refuses_earlier_local :: proc(t: ^testing.T) {
	expect_no_lift(t, LIFT_INNER, "main :: proc() {\n\tx := 1\n\ta: Outer\n\tfoo(a.mid.inner.{*}y)\n}\n")
}

@(test)
lift_using_refuses_later_declaration :: proc(t: ^testing.T) {
	expect_no_lift(t, LIFT_INNER, "main :: proc() {\n\ta: Outer\n\tfoo(a.mid.inner.{*}y)\n\tx := 1\n}\n")
}

@(test)
lift_using_refuses_nested_local_named_like_a_field :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		LIFT_INNER,
		"main :: proc() {\n\ta: Outer\n\tfoo(a.mid.inner.{*}y)\n\tif ok() {\n\t\tx := 1\n\t\tbar(x, a.mid.inner.x)\n\t}\n}\n",
	)
}

@(test)
lift_using_refuses_kept_root_named_like_a_field :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		"Lift using value",
		"Value :: struct {\n\tvalue: int,\n}\n\nmain :: proc() {\n\tvalue: Value\n\tfoo(value.{*}value)\n}\n",
	)
}

@(test)
lift_using_refuses_shared_line :: proc(t: ^testing.T) {
	expect_no_lift(t, LIFT_INNER, "main :: proc() {\n\ta: Outer\n\tstart(); foo(a.mid.inner.{*}x)\n}\n")
}

@(test)
lift_using_refuses_when_body :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		LIFT_INNER,
		"main :: proc() {\n\ta: Outer\n\twhen ODIN_DEBUG {\n\t\tfoo(a.mid.inner.{*}x)\n\t}\n}\n",
	)
}

@(test)
lift_using_refuses_case_label :: proc(t: ^testing.T) {
	expect_no_lift(
		t,
		LIFT_INNER,
		"main :: proc() {\n\ta: Outer\n\tswitch n() {\n\tcase a.mid.inner.{*}x:\n\t\tfoo()\n\t}\n}\n",
	)
}
