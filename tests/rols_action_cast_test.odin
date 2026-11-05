#+feature dynamic-literals
package tests

import "core:strings"
import "core:testing"

import test "src:testing"

TO_CALL :: "Convert to T(x)"
TO_CAST :: "Convert to cast(T)x"
TO_AUTO :: "Convert to auto_cast"
TO_TRANSMUTE :: "Convert to transmute"

CAST_PRELUDE :: `package test

P :: struct {
	x: int,
}

Box :: struct($T: typeid) {
	v: T,
}

Mb :: union($T: typeid) {
	T,
}

Cb :: proc(a: int)

take :: proc(a: f32) {}
take_p :: proc(a: P) {}
twice :: proc(a: int) -> int {
	return a * 2
}

`

// body with `{*}` for the cursor, in a procedure with locals f, i, p and r.
cast_source :: proc(body: string) -> string {
	return strings.concatenate(
		{CAST_PRELUDE, "main :: proc() {\n\tf: f32\n\ti: int\n\tp: ^int\n\tr: rawptr\n\t", body, "\n}\n"},
		context.temp_allocator,
	)
}

expect_cast :: proc(t: ^testing.T, title, body, expected: string) {
	source := test.Source {
		main = cast_source(body),
		config = {enable_code_action_cast = true},
	}
	test.expect_action_applied(t, &source, title, cast_source(expected))
}

expect_no_cast :: proc(t: ^testing.T, title, body: string) {
	source := test.Source {
		main = cast_source(body),
		config = {enable_code_action_cast = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
cast_and_call_both_ways :: proc(t: ^testing.T) {
	expect_cast(t, TO_CALL, "x := ca{*}st(int)f\n\t_ = x", "x := int(f)\n\t_ = x")
	expect_cast(t, TO_CAST, "x := in{*}t(f)\n\t_ = x", "x := cast(int)f\n\t_ = x")
}

@(test)
cast_call_form_takes_parentheses_for_a_written_type :: proc(t: ^testing.T) {
	expect_cast(t, TO_CALL, "x := ca{*}st(^f32)p\n\t_ = x", "x := (^f32)(p)\n\t_ = x")
	expect_cast(t, TO_CAST, "x := (^f{*}32)(p)\n\t_ = x", "x := cast(^f32)p\n\t_ = x")
	expect_cast(t, TO_CALL, "x := ca{*}st(proc())r\n\t_ = x", "x := (proc())(r)\n\t_ = x")
	expect_cast(t, TO_CAST, "x := (pr{*}oc())(r)\n\t_ = x", "x := cast(proc())r\n\t_ = x")
	expect_cast(t, TO_CALL, "x := ca{*}st([]u8)\"a\"\n\t_ = x", "x := ([]u8)(\"a\")\n\t_ = x")
}

@(test)
cast_operand_keeps_its_grouping :: proc(t: ^testing.T) {
	expect_cast(t, TO_CAST, "x := in{*}t(f + 1)\n\t_ = x", "x := cast(int)(f + 1)\n\t_ = x")
	expect_cast(t, TO_CALL, "x := ca{*}st(int)(f + 1)\n\t_ = x", "x := int(f + 1)\n\t_ = x")
	expect_cast(t, TO_CALL, "x := ca{*}st(int)f + 1\n\t_ = x", "x := int(f) + 1\n\t_ = x")
}

@(test)
cast_wraps_before_a_postfix_operator :: proc(t: ^testing.T) {
	expect_cast(t, TO_CAST, "x := (^P{*})(r).x\n\t_ = x", "x := (cast(^P)r).x\n\t_ = x")
}

@(test)
cast_auto_cast_both_ways_in_each_place :: proc(t: ^testing.T) {
	expect_cast(t, TO_AUTO, "x: int = ca{*}st(int)f\n\t_ = x", "x: int = auto_cast f\n\t_ = x")
	expect_cast(t, TO_CAST, "x: int = auto{*}_cast f\n\t_ = x", "x: int = cast(int)f\n\t_ = x")
	expect_cast(t, TO_AUTO, "x: int = in{*}t(f + 1)\n\t_ = x", "x: int = auto_cast (f + 1)\n\t_ = x")
	expect_cast(t, TO_AUTO, "take(ca{*}st(f32)i)", "take(auto_cast i)")
	expect_cast(t, TO_CAST, "take(auto{*}_cast i)", "take(cast(f32)i)")
	expect_cast(t, TO_AUTO, "i = ca{*}st(int)f", "i = auto_cast f")
	expect_cast(t, TO_CAST, "i = auto{*}_cast f", "i = cast(int)f")
	expect_cast(t, TO_AUTO, "v := P{x = ca{*}st(int)f}\n\t_ = v", "v := P{x = auto_cast f}\n\t_ = v")
	expect_cast(t, TO_CAST, "v := P{x = auto{*}_cast f}\n\t_ = v", "v := P{x = cast(int)f}\n\t_ = v")
}

@(test)
cast_transmute_both_ways_between_pointers :: proc(t: ^testing.T) {
	expect_cast(t, TO_TRANSMUTE, "x := ca{*}st(^f32)p\n\t_ = x", "x := transmute(^f32)p\n\t_ = x")
	expect_cast(t, TO_CAST, "x := trans{*}mute(^f32)p\n\t_ = x", "x := cast(^f32)p\n\t_ = x")
	expect_cast(t, TO_TRANSMUTE, "x := ca{*}st(^f32)r\n\t_ = x", "x := transmute(^f32)r\n\t_ = x")
	expect_cast(t, TO_TRANSMUTE, "x := ca{*}st(rawptr)p\n\t_ = x", "x := transmute(rawptr)p\n\t_ = x")
	expect_cast(
		t,
		TO_TRANSMUTE,
		"m: [^]int\n\tx := ca{*}st(^int)m\n\t_ = x",
		"m: [^]int\n\tx := transmute(^int)m\n\t_ = x",
	)
}

@(test)
cast_refuses_a_call_that_is_no_conversion :: proc(t: ^testing.T) {
	expect_no_cast(t, TO_CAST, "x := twi{*}ce(i)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x := si{*}ze_of(i)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x: Bo{*}x(int)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x := in{*}t(f, f)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x: M{*}b(int)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x := C{*}b(r)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "h := twice\n\tx := {*}h(i)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "h := 1\n\tx := {*}h(i)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x := #force_inline in{*}t(f)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x := in{*}t(..f)\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x := in{*}t(a = f)\n\t_ = x")
}

@(test)
cast_refuses_a_selection_past_the_cast :: proc(t: ^testing.T) {
	expect_no_cast(t, TO_CALL, "x := {[cast(int)f + 1]}\n\t_ = x")
}

@(test)
cast_auto_cast_needs_the_place_to_expect_the_type :: proc(t: ^testing.T) {
	expect_no_cast(t, TO_AUTO, "x := ca{*}st(int)f\n\t_ = x")
	expect_no_cast(t, TO_AUTO, "x: f64 = ca{*}st(int)f\n\t_ = x")
	expect_no_cast(t, TO_AUTO, "x := ca{*}st(int)f + 1\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x := auto{*}_cast f + 1\n\t_ = x")
	// An inline struct written again is a new type, and a local can shadow the name of the type.
	expect_no_cast(t, TO_CAST, "s: struct {\n\t\tx: int,\n\t}\n\ts = auto{*}_cast i")
	expect_no_cast(t, TO_CAST, "f32 := 1\n\t_ = f32\n\ttake(auto{*}_cast i)")
	expect_no_cast(t, TO_CAST, "v: P\n\tP := 1\n\t_ = P\n\ttake_p(auto{*}_cast v)")
}

@(test)
cast_auto_cast_takes_a_named_type :: proc(t: ^testing.T) {
	expect_cast(t, TO_AUTO, "v: P\n\tv.x = ca{*}st(int)f", "v: P\n\tv.x = auto_cast f")
	expect_cast(t, TO_AUTO, "v: P\n\tw: P = ca{*}st(P)v\n\t_ = w", "v: P\n\tw: P = auto_cast v\n\t_ = w")
	expect_cast(t, TO_CAST, "v: P\n\tw: P = auto{*}_cast v\n\t_ = w", "v: P\n\tw: P = cast(P)v\n\t_ = w")
}

@(test)
cast_transmute_needs_pointers_on_both_sides :: proc(t: ^testing.T) {
	expect_no_cast(t, TO_TRANSMUTE, "x := ca{*}st(int)f\n\t_ = x")
	expect_no_cast(t, TO_TRANSMUTE, "x := ca{*}st(uintptr)p\n\t_ = x")
	expect_no_cast(t, TO_TRANSMUTE, "u: uintptr\n\tx := ca{*}st(^int)u\n\t_ = x")
	expect_no_cast(t, TO_CAST, "x := trans{*}mute(u32)f\n\t_ = x")
}

@(test)
cast_off_with_its_flag :: proc(t: ^testing.T) {
	cases := [][2]string {
		{TO_CALL, "x := ca{*}st(int)f\n\t_ = x"},
		{TO_CAST, "x := in{*}t(f)\n\t_ = x"},
		{TO_AUTO, "x: int = ca{*}st(int)f\n\t_ = x"},
		{TO_CAST, "x: int = auto{*}_cast f\n\t_ = x"},
		{TO_TRANSMUTE, "x := ca{*}st(^f32)p\n\t_ = x"},
		{TO_CAST, "x := trans{*}mute(^f32)p\n\t_ = x"},
	}
	for item in cases {
		source := test.Source {
			main = cast_source(item[1]),
			config = {enable_code_action_cast = false},
		}
		test.expect_action_missing(t, &source, item[0])
	}
}

// A distinct type does not take its base type, so the cast names the distinct type.
@(test)
cast_from_auto_assigns_a_distinct_type :: proc(t: ^testing.T) {
	expect_cast(
		t,
		TO_CAST,
		"Handle :: distinct u32\n\th: Handle\n\th = auto{*}_cast f\n\t_ = h",
		"Handle :: distinct u32\n\th: Handle\n\th = cast(Handle)f\n\t_ = h",
	)
}

@(test)
cast_from_auto_assigns_a_distinct_field :: proc(t: ^testing.T) {
	expect_cast(
		t,
		TO_CAST,
		"Handle :: distinct u32\n\tS :: struct {\n\t\tid: Handle,\n\t}\n\ts: S\n\ts.id = auto{*}_cast f\n\t_ = s",
		"Handle :: distinct u32\n\tS :: struct {\n\t\tid: Handle,\n\t}\n\ts: S\n\ts.id = cast(Handle)f\n\t_ = s",
	)
}

@(test)
cast_from_auto_qualifies_a_distinct_type_of_another_package :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\nimport \"core:other\"\nmain :: proc() {\n\tf: f32\n\th: other.Handle\n\th = auto{*}_cast f\n\t_ = h\n}\n",
		packages = {{pkg = "other", source = "package other\nHandle :: distinct u32\n"}},
		collections = {"core" = "test"},
		config = {enable_code_action_cast = true},
	}
	test.expect_action_applied(
		t,
		&source,
		TO_CAST,
		"package test\nimport \"core:other\"\nmain :: proc() {\n\tf: f32\n\th: other.Handle\n\th = cast(other.Handle)f\n\t_ = h\n}\n",
	)
}

@(test)
cast_from_auto_assigns_a_distinct_type_at_file_scope :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\nHandle :: distinct u32\nmain :: proc() {\n\tf: f32\n\th: Handle\n\th = auto{*}_cast f\n\t_ = h\n}\n",
		config = {enable_code_action_cast = true},
	}
	test.expect_action_applied(
		t,
		&source,
		TO_CAST,
		"package test\nHandle :: distinct u32\nmain :: proc() {\n\tf: f32\n\th: Handle\n\th = cast(Handle)f\n\t_ = h\n}\n",
	)
}
