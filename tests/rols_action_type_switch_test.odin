package tests

import "core:strings"
import "core:testing"

import test "src:testing"

TO_TYPE_SWITCH :: "Convert to type switch"
TO_IF_CHAIN :: "Convert to if chain"
ADD_PARTIAL :: "Add #partial"
REMOVE_PARTIAL :: "Remove #partial"
ADD_DEFAULT :: "Add default case"

TYPE_SWITCH_PRELUDE :: `package test

T :: struct {
	x: int,
	f: proc(t: ^T),
}

U :: union {
	int,
	string,
	T,
}

`

// body with `{*}` for the cursor, in a procedure with a local u and a local a.
type_switch_source :: proc(body: string) -> string {
	return strings.concatenate(
		{TYPE_SWITCH_PRELUDE, "main :: proc() {\n\tu: U\n\ta: any\n\t", body, "\n\t_ = a\n}\n"},
		context.temp_allocator,
	)
}

expect_type_switch :: proc(t: ^testing.T, title, body, expected: string) {
	source := test.Source {
		main = type_switch_source(body),
		config = {enable_code_action_type_switch = true},
	}
	test.expect_action_applied(t, &source, title, type_switch_source(expected))
}

expect_no_type_switch :: proc(t: ^testing.T, title, body: string) {
	source := test.Source {
		main = type_switch_source(body),
		config = {enable_code_action_type_switch = true},
	}
	test.expect_action_missing(t, &source, title)
}

CHAIN_BODY :: "if v, ok := u.(int); ok {\n\t\t_ = v\n\t} else if v, ok := u.(string); ok {\n\t\t_ = v\n\t} else {\n\t\t_ = 1\n\t}"
SWITCH_BODY :: "#partial switch v in u {\n\tcase int:\n\t\t_ = v\n\tcase string:\n\t\t_ = v\n\tcase:\n\t\t_ = 1\n\t}"

@(test)
type_switch_from_a_chain :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_TYPE_SWITCH,
		strings.concatenate({"{*}", CHAIN_BODY}, context.temp_allocator),
		SWITCH_BODY,
	)
}

@(test)
type_switch_from_the_else_if_line :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_TYPE_SWITCH,
		"if v, ok := u.(int); ok {\n\t\t_ = v\n\t} else if v, ok := {*}u.(string); ok {\n\t\t_ = v\n\t} else {\n\t\t_ = 1\n\t}",
		SWITCH_BODY,
	)
}

@(test)
type_switch_to_a_chain :: proc(t: ^testing.T) {
	expect_type_switch(t, TO_IF_CHAIN, strings.concatenate({"{*}", SWITCH_BODY}, context.temp_allocator), CHAIN_BODY)
}

@(test)
type_switch_round_trip_restores_the_text :: proc(t: ^testing.T) {
	source := test.Source {
		main = type_switch_source(strings.concatenate({"{*}", CHAIN_BODY}, context.temp_allocator)),
		config = {enable_code_action_type_switch = true},
	}
	test.expect_action_round_trip(t, &source, {TO_TYPE_SWITCH, TO_IF_CHAIN}, {"#partial"})
}

@(test)
type_switch_writes_no_partial_when_every_variant_has_a_case :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_TYPE_SWITCH,
		"i{*}f v, ok := u.(int); ok {\n\t\t_ = v\n\t} else if _, ok := u.(string); ok {\n\t} else if _, ok := u.(T); ok {\n\t}",
		"switch v in u {\n\tcase int:\n\t\t_ = v\n\tcase string:\n\tcase T:\n\t}",
	)
}

@(test)
type_switch_on_any_takes_no_partial :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_TYPE_SWITCH,
		"i{*}f v, ok := a.(int); ok {\n\t\t_ = v\n\t}",
		"switch v in a {\n\tcase int:\n\t\t_ = v\n\t}",
	)
}

@(test)
type_switch_chain_binds_blank_for_a_case_without_the_binding :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_IF_CHAIN,
		"sw{*}itch v in u {\n\tcase int:\n\t\t_ = v\n\tcase string:\n\tcase T:\n\t}",
		"if v, ok := u.(int); ok {\n\t\t_ = v\n\t} else if _, ok := u.(string); ok {\n\t} else if _, ok := u.(T); ok {\n\t}",
	)
}

@(test)
type_switch_chain_takes_a_free_flag_name :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_IF_CHAIN,
		"ok := 1\n\t#partial sw{*}itch v in u {\n\tcase int:\n\t\t_ = v + ok\n\t}",
		"ok := 1\n\tif v, ok2 := u.(int); ok2 {\n\t\t_ = v + ok\n\t}",
	)
}

@(test)
type_switch_chain_avoids_a_flag_name_declared_elsewhere :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_IF_CHAIN,
		"#partial sw{*}itch v in u {\n\tcase int:\n\t\tok := v\n\t\t_ = ok\n\t}",
		"if v, ok2 := u.(int); ok2 {\n\t\tok := v\n\t\t_ = ok\n\t}",
	)
	expect_type_switch(
		t,
		TO_IF_CHAIN,
		"ok := 1\n\t_ = ok\n\t#partial sw{*}itch v in u {\n\tcase int:\n\t\t_ = v\n\t}",
		"ok := 1\n\t_ = ok\n\tif v, ok2 := u.(int); ok2 {\n\t\t_ = v\n\t}",
	)
}

@(test)
type_switch_chain_allows_fallthrough_of_an_inner_switch :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_IF_CHAIN,
		"#partial sw{*}itch v in u {\n\tcase int:\n\t\tswitch v {\n\t\tcase 1:\n\t\t\tfallthrough\n\t\tcase 2:\n\t\t}\n\t}",
		"if v, ok := u.(int); ok {\n\t\tswitch v {\n\t\tcase 1:\n\t\t\tfallthrough\n\t\tcase 2:\n\t\t}\n\t}",
	)
}

@(test)
type_switch_chain_moves_an_indented_case_body :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_IF_CHAIN,
		"#partial sw{*}itch v in u {\n\t\tcase int:\n\t\t\t_ = v\n\t}",
		"if v, ok := u.(int); ok {\n\t\t_ = v\n\t}",
	)
}

@(test)
type_switch_refuses_a_chain :: proc(t: ^testing.T) {
	cases := []string {
		// The flag is used in a body.
		"i{*}f v, ok := u.(int); ok {\n\t\t_ = ok\n\t\t_ = v\n\t}",
		// `else` uses the binding.
		"i{*}f v, ok := u.(int); ok {\n\t\t_ = v\n\t} else {\n\t\t_ = v\n\t}",
		// `break` would target the switch.
		"for {\n\t\ti{*}f v, ok := u.(int); ok {\n\t\t\t_ = v\n\t\t\tbreak\n\t\t}\n\t}",
		// Another subject, another binding, or another shape.
		"w: U\n\ti{*}f v, ok := u.(int); ok {\n\t\t_ = v\n\t} else if v, ok := w.(string); ok {\n\t\t_ = v\n\t}",
		"i{*}f v, ok := u.(int); ok {\n\t\t_ = v\n\t} else if w, ok := u.(string); ok {\n\t\t_ = w\n\t}",
		"i{*}f v, ok := u.(int); ok {\n\t\t_ = v\n\t} else if a != nil {\n\t}",
		"i{*}f v, ok := u.(int); !ok {\n\t\t_ = v\n\t}",
		"i{*}f v := 1; v > 0 {\n\t}",
		"i{*}f v, ok := u.?; ok {\n\t\t_ = v\n\t}",
		// The binding of a switch cannot change.
		"i{*}f v, ok := u.(int); ok {\n\t\tv = 1\n\t}",
		"i{*}f v, ok := u.(T); ok {\n\t\tv.x = 1\n\t}",
		"i{*}f v, ok := u.(T); ok {\n\t\t_ = &v\n\t}",
		// A blank link would capture a name that the switch binds.
		"v := 1\n\ti{*}f v, ok := u.(int); ok {\n\t\t_ = v\n\t} else if _, ok := u.(string); ok {\n\t\t_ = v\n\t}",
		// A repeated type, a repeated call, and a pointer that binds another type in a switch.
		"i{*}f _, ok := u.(int); ok {\n\t} else if _, ok := u.(int); ok {\n\t}",
		"f :: proc() -> U {return nil}\n\ti{*}f _, ok := f().(int); ok {\n\t} else if _, ok := f().(string); ok {\n\t}",
		"p := &u\n\ti{*}f _, ok := p.(int); ok {\n\t}",
		// A comment between the branches has no place in a switch.
		"i{*}f _, ok := u.(int); ok {\n\t} /* note */ else if _, ok := u.(string); ok {\n\t}",
		// A cursor in a body means the code of that body.
		"if v, ok := u.(int); ok {\n\t\t_ = {*}v\n\t}",
		// A switch cannot follow `else`.
		"if a != nil {\n\t} else if v, ok := {*}u.(int); ok {\n\t\t_ = v\n\t}",
	}
	for body in cases {
		expect_no_type_switch(t, TO_TYPE_SWITCH, body)
	}
}

@(test)
type_switch_refuses_a_chain_shape :: proc(t: ^testing.T) {
	cases := []string {
		// A label, `do`, and a declared type.
		"l: i{*}f v, ok := u.(int); ok {\n\t\t_ = v\n\t}",
		"i{*}f v, ok := u.(int); ok do _ = v",
		"i{*}f _, ok := u.(int); ok {\n\t} else do _ = 1",
		"i{*}f v, ok: any = u.(int); ok {\n\t\t_ = v\n\t}",
		// The condition is not the flag.
		"i{*}f v, _ := u.(int); _ {\n\t}",
		"other := true\n\ti{*}f v, ok := u.(int); other {\n\t\t_ = v\n\t}",
		// A comment after `else`.
		"i{*}f _, ok := u.(int); ok {\n\t} else /* note */ if _, ok := u.(string); ok {\n\t}",
		// `break` in the `else` would target the switch.
		"for {\n\t\ti{*}f _, ok := u.(int); ok {\n\t\t} else {\n\t\t\tbreak\n\t\t}\n\t}",
		// A repeated call inside the subject.
		"g :: proc() -> int {return 0}\n\tus: []U\n\ti{*}f _, ok := us[g()].(int); ok {\n\t} else if _, ok := us[g()].(string); ok {\n\t}",
		// The subject names the flag or the binding.
		"ok: U\n\ti{*}f v, ok := ok.(int); ok {\n\t\t_ = v\n\t}",
		"v: U\n\ti{*}f v, ok := v.(int); ok {\n\t\t_ = v\n\t}",
		// The `else` reads the flag.
		"i{*}f v, ok := u.(int); ok {\n\t\t_ = v\n\t} else {\n\t\t_ = ok\n\t}",
		// The binding of a switch takes no `->` call, no slice of an array, and no `for &e`.
		"i{*}f v, ok := u.(T); ok {\n\t\tv->f()\n\t}",
		"W :: union {\n\t\t[2]int,\n\t}\n\tw: W\n\ti{*}f v, ok := w.([2]int); ok {\n\t\t_ = v[:]\n\t}",
		"W :: union {\n\t\t[2]int,\n\t}\n\tw: W\n\ti{*}f v, ok := w.([2]int); ok {\n\t\tfor &e in v {\n\t\t\t_ = e\n\t\t}\n\t}",
		// A subject that is neither a union nor an `any`.
		"n: int\n\ti{*}f v, ok := n.(int); ok {\n\t\t_ = v\n\t}",
	}
	for body in cases {
		expect_no_type_switch(t, TO_TYPE_SWITCH, body)
	}
}

@(test)
type_switch_chain_keeps_a_field_named_like_the_flag :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_TYPE_SWITCH,
		"i{*}f v, x := u.(T); x {\n\t\t_ = v.x\n\t}",
		"#partial switch v in u {\n\tcase T:\n\t\t_ = v.x\n\t}",
	)
	expect_type_switch(
		t,
		TO_TYPE_SWITCH,
		"i{*}f _, x := u.(T); x {\n\t} else {\n\t\tc: T\n\t\t_ = c.x\n\t}",
		"#partial switch _ in u {\n\tcase T:\n\tcase:\n\t\tc: T\n\t\t_ = c.x\n\t}",
	)
}

@(test)
type_switch_chain_slices_a_slice_binding :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		TO_TYPE_SWITCH,
		"i{*}f v, ok := u.(string); ok {\n\t\t_ = v[:]\n\t}",
		"#partial switch v in u {\n\tcase string:\n\t\t_ = v[:]\n\t}",
	)
}

@(test)
type_switch_refuses_a_switch :: proc(t: ^testing.T) {
	cases := []string {
		"sw{*}itch v in u {\n\tcase int:\n\t\tfallthrough\n\tcase string, T:\n\t\t_ = 1\n\t}",
		"#partial sw{*}itch v in u {\n\tcase int:\n\t\tfallthrough\n\tcase string:\n\t}",
		// More than one type gives the binding the type of the union.
		"#partial sw{*}itch v in u {\n\tcase int, string:\n\t\t_ = v\n\t}",
		"#partial sw{*}itch v in u {\n\tcase nil:\n\t}",
		// A default case uses the binding, or is not last, or stands alone.
		"#partial sw{*}itch v in u {\n\tcase int:\n\tcase:\n\t\t_ = v\n\t}",
		"#partial sw{*}itch v in u {\n\tcase:\n\tcase int:\n\t}",
		"#partial sw{*}itch v in u {\n\tcase:\n\t}",
		// A reference, a label, and `break`.
		"#partial sw{*}itch &v in u {\n\tcase int:\n\t\t_ = v\n\t}",
		"l: #partial sw{*}itch v in u {\n\tcase int:\n\t\t_ = v\n\t\tbreak l\n\t}",
		"#partial sw{*}itch v in u {\n\tcase int:\n\t\tbreak\n\t}",
		// A pointer binds another type in a switch.
		"p := &u\n\t#partial sw{*}itch v in p {\n\tcase int:\n\t}",
		// A repeated call.
		"f :: proc() -> U {return nil}\n\t#partial sw{*}itch v in f() {\n\tcase int:\n\tcase string:\n\t}",
		// A repeated call inside the subject.
		"g :: proc() -> int {return 0}\n\tus: []U\n\t#partial sw{*}itch v in us[g()] {\n\tcase int:\n\tcase string:\n\t}",
		// A cursor in a body means the code of that body.
		"#partial switch v in u {\n\tcase int:\n\t\t_ = {*}v\n\t}",
		// No case, a subject that takes no `.(T)`, and a binding that the subject reads.
		"#partial sw{*}itch v in u {\n\t}",
		"w: U\n\t#partial sw{*}itch v in a != nil ? u : w {\n\tcase int:\n\t}",
		"v: U\n\t#partial sw{*}itch v in v {\n\tcase int:\n\t}",
		// A comment after `#partial` hides where the directive starts.
		"#partial /* note */ sw{*}itch v in u {\n\tcase int:\n\t}",
		// A multi-line string in an indented case cannot move.
		"#partial sw{*}itch v in u {\n\t\tcase int:\n\t\t\t_ = `a\nb`\n\t}",
	}
	for body in cases {
		expect_no_type_switch(t, TO_IF_CHAIN, body)
	}
}

@(test)
type_switch_refuses_more_than_eight_cases :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "sw{*}itch v in a {\n")
	for type in ([]string{"int", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64"}) {
		strings.write_string(&sb, "\tcase ")
		strings.write_string(&sb, type)
		strings.write_string(&sb, ":\n")
	}
	strings.write_string(&sb, "\t}")
	expect_no_type_switch(t, TO_IF_CHAIN, strings.to_string(sb))
}

@(test)
type_switch_partial_both_ways :: proc(t: ^testing.T) {
	complete := "switch v in u {\n\tcase int:\n\tcase string:\n\tcase T:\n\t}"
	expect_type_switch(
		t,
		ADD_PARTIAL,
		"sw{*}itch v in u {\n\tcase int:\n\tcase string:\n\tcase T:\n\t}",
		"#partial switch v in u {\n\tcase int:\n\tcase string:\n\tcase T:\n\t}",
	)
	expect_type_switch(
		t,
		REMOVE_PARTIAL,
		"#partial sw{*}itch v in u {\n\tcase int:\n\tcase string:\n\tcase T:\n\t}",
		complete,
	)
	expect_type_switch(
		t,
		REMOVE_PARTIAL,
		"#par{*}tial switch v in u {\n\tcase int:\n\tcase string:\n\tcase T:\n\t}",
		complete,
	)
}

@(test)
type_switch_partial_refuses :: proc(t: ^testing.T) {
	// Every case must be present, and a default case does not count.
	expect_no_type_switch(t, REMOVE_PARTIAL, "#partial sw{*}itch v in u {\n\tcase int:\n\tcase string:\n\t}")
	expect_no_type_switch(t, REMOVE_PARTIAL, "#partial sw{*}itch v in u {\n\tcase int:\n\tcase string:\n\tcase:\n\t}")
	expect_no_type_switch(
		t,
		REMOVE_PARTIAL,
		"#partial sw{*}itch v in u {\n\tcase int:\n\tcase string:\n\tcase bool:\n\t}",
	)
	// A pointer and its element share a name, and `nil` is no variant.
	both := "P :: union {\n\t\tint,\n\t\t^int,\n\t}\n\tp: P\n\t"
	expect_no_type_switch(
		t,
		REMOVE_PARTIAL,
		strings.concatenate({both, "#partial sw{*}itch v in p {\n\tcase int:\n\t}"}, context.temp_allocator),
	)
	expect_no_type_switch(
		t,
		REMOVE_PARTIAL,
		strings.concatenate(
			{both, "#partial sw{*}itch v in p {\n\tcase nil:\n\tcase int:\n\t}"},
			context.temp_allocator,
		),
	)
	// A comment after `#partial` hides where the directive starts.
	expect_no_type_switch(
		t,
		REMOVE_PARTIAL,
		"#partial /* note */ sw{*}itch v in u {\n\tcase int:\n\tcase string:\n\tcase T:\n\t}",
	)
	expect_no_type_switch(t, ADD_PARTIAL, "#partial sw{*}itch v in u {\n\tcase int:\n\t}")
	// `#partial` applies only to a union.
	expect_no_type_switch(t, ADD_PARTIAL, "sw{*}itch v in a {\n\tcase int:\n\t}")
}

@(test)
type_switch_adds_a_default_case :: proc(t: ^testing.T) {
	expect_type_switch(
		t,
		ADD_DEFAULT,
		"#partial sw{*}itch v in u {\n\tcase int:\n\t\t_ = v\n\t}",
		"#partial switch v in u {\n\tcase int:\n\t\t_ = v\n\tcase:\n\t}",
	)
	expect_type_switch(
		t,
		ADD_DEFAULT,
		"#partial sw{*}itch v in u {\n\t\tcase int:\n\t}",
		"#partial switch v in u {\n\t\tcase int:\n\t\tcase:\n\t}",
	)
	expect_no_type_switch(t, ADD_DEFAULT, "#partial sw{*}itch v in u {\n\tcase int:\n\tcase:\n\t}")
	expect_no_type_switch(t, ADD_DEFAULT, "#partial sw{*}itch v in u { case int: }")
}

@(test)
type_switch_off_with_its_flag :: proc(t: ^testing.T) {
	cases := [][2]string {
		{TO_TYPE_SWITCH, "i{*}f v, ok := u.(int); ok {\n\t\t_ = v\n\t}"},
		{TO_IF_CHAIN, "#partial sw{*}itch v in u {\n\tcase int:\n\t\t_ = v\n\t}"},
		{ADD_PARTIAL, "sw{*}itch v in u {\n\tcase int:\n\tcase string:\n\tcase T:\n\t}"},
		{REMOVE_PARTIAL, "#partial sw{*}itch v in u {\n\tcase int:\n\tcase string:\n\tcase T:\n\t}"},
		{ADD_DEFAULT, "#partial sw{*}itch v in u {\n\tcase int:\n\t}"},
	}
	for item in cases {
		source := test.Source {
			main = type_switch_source(item[1]),
			config = {enable_code_action_type_switch = false},
		}
		test.expect_action_missing(t, &source, item[0])
	}
}
