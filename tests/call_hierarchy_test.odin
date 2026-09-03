package tests

import "core:testing"

import "src:common"

import test "src:testing"

@(private = "file")
CALL_GRAPH_MAIN :: `package test

fo{*}o :: proc(x: int) -> int {
	bar()
	baz()
	return bar()
}

bar :: proc() -> int {
	return 1
}

baz :: proc() {}
`

@(private = "file")
CALL_GRAPH_B :: `package test

qux :: proc() {
	foo(1)
	g()
}

g :: proc{foo, bar}
`

@(private = "file")
CALL_GRAPH_FILES := []test.File{{"b.odin", CALL_GRAPH_B}}

@(private = "file")
call_graph :: proc() -> test.Source {
	return {main = CALL_GRAPH_MAIN, files = CALL_GRAPH_FILES}
}

@(test)
call_hierarchy_prepare :: proc(t: ^testing.T) {
	source := call_graph()
	test.expect_call_hierarchy_item(t, &source, "foo")
}

@(test)
call_hierarchy_prepare_not_a_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
LIM{*}IT :: 10
`,
	}
	test.expect_call_hierarchy_item(t, &source, "")
}

@(test)
call_hierarchy_outgoing :: proc(t: ^testing.T) {
	source := call_graph()
	test.expect_outgoing_calls(t, &source, {{"bar", 2}, {"baz", 1}})
}

@(test)
call_hierarchy_outgoing_skips_conversions_and_builtins :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
Meters :: distinct int

fo{*}o :: proc(s: string) -> Meters {
	return Meters(len(s))
}
`,
	}
	test.expect_outgoing_calls(t, &source, {})
}

@(test)
call_hierarchy_incoming :: proc(t: ^testing.T) {
	source := call_graph()
	test.expect_incoming_calls(t, &source, {{"qux", 1}, {"g", 1}})
}

@(test)
call_hierarchy_outgoing_from_group :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
foo :: proc(x: int) {}
bar :: proc(x: f32) {}
g{*} :: proc{foo, bar}
`,
	}
	test.expect_outgoing_calls(t, &source, {{"foo", 1}, {"bar", 1}})
}

@(test)
implementation_of_proc_group :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
foo :: proc(x: int) {}
bar :: proc(x: f32) {}
g :: proc{foo, bar}

main :: proc() {
	g{*}(1)
}
`,
	}
	test.expect_implementation_locations(
		t,
		&source,
		{
			{range = {start = {line = 1, character = 0}, end = {line = 1, character = 3}}},
			{range = {start = {line = 2, character = 0}, end = {line = 2, character = 3}}},
		},
	)
}

@(test)
implementation_of_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
foo :: proc(x: int) {}

main :: proc() {
	fo{*}o(1)
}
`,
	}
	test.expect_implementation_locations(t, &source, {{range = {start = {line = 1, character = 0}, end = {line = 1, character = 3}}}})
}
