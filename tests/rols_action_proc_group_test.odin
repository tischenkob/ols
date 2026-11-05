package tests

import "core:testing"

import test "src:testing"

@(private = "file")
MAKE_GROUP :: "Make group draw"
@(private = "file")
ADD_TO_GROUP :: "Add to group draw"

@(private = "file")
group_source :: proc(main: string, files: []test.File = {}, enabled := true) -> test.Source {
	return {main = main, files = files, config = {enable_code_action_proc_group = enabled}}
}

@(private = "file")
expect_no_proc_group :: proc(t: ^testing.T, title, main: string, files: []test.File = {}, enabled := true) {
	source := group_source(main, files, enabled)
	test.expect_action_missing(t, &source, title)
}

@(private = "file")
DRAWS :: `package test

dr{*}aw_int :: proc(v: int) {}

draw_str :: proc(s: string) {}

redraw :: proc() {}
`

@(test)
proc_group_make_group_lists_the_siblings :: proc(t: ^testing.T) {
	source := group_source(DRAWS)
	test.expect_action_applied(
		t,
		&source,
		MAKE_GROUP,
		`package test

draw_int :: proc(v: int) {}

draw_str :: proc(s: string) {}

draw :: proc{draw_int, draw_str}

redraw :: proc() {}
`,
	)
}

// The group lives in another file of the package and is not called with the arguments that the procedure takes.
@(test)
proc_group_add_to_group_in_another_file :: proc(t: ^testing.T) {
	source := group_source(
		`package test

draw_point :: proc(x: f32, y: f32) {}

draw_{*}f32 :: proc(f: f32) {}
`,
		{{"b.odin", `package test

draw :: proc{draw_point}

main :: proc() {
	draw(1, 2)
}
`}},
	)
	test.expect_action_applied_files(
		t,
		&source,
		ADD_TO_GROUP,
		{{"b.odin", `package test

draw :: proc{draw_point, draw_f32}

main :: proc() {
	draw(1, 2)
}
`}},
	)
}

@(test)
proc_group_refuses :: proc(t: ^testing.T) {
	// No sibling shares the prefix.
	expect_no_proc_group(t, MAKE_GROUP, "package test\n\ndr{*}aw_int :: proc(v: int) {}\n\nredraw :: proc() {}\n")
	// The name is taken.
	expect_no_proc_group(
		t,
		MAKE_GROUP,
		"package test\n\ndraw := 1\n\ndr{*}aw_int :: proc(v: int) {}\n\ndraw_str :: proc(s: string) {}\n",
	)
	// Two siblings take the same parameter types.
	expect_no_proc_group(
		t,
		MAKE_GROUP,
		"package test\n\ndr{*}aw_int :: proc(v: int) {}\n\ndraw_count :: proc(n: int) {}\n",
	)
	// A variable holds a procedure that can change.
	expect_no_proc_group(
		t,
		MAKE_GROUP,
		"package test\n\ndr{*}aw_int := proc(v: int) {}\n\ndraw_str :: proc(s: string) {}\n",
	)
	// The group already holds the procedure.
	expect_no_proc_group(t, ADD_TO_GROUP, "package test\n\ndr{*}aw_int :: proc(v: int) {}\n\ndraw :: proc{draw_int}\n")
	// A call of the group with one argument could pick the new member.
	expect_no_proc_group(
		t,
		ADD_TO_GROUP,
		"package test\n\ndraw_str :: proc(s: string) {}\n\ndraw_i{*}nt :: proc(v: int) {}\n\ndraw :: proc{draw_str}\n\nmain :: proc() {\n\tdraw(\"a\")\n}\n",
	)
	// A member with the same parameter types.
	expect_no_proc_group(
		t,
		ADD_TO_GROUP,
		"package test\n\ndraw_count :: proc(n: int) {}\n\ndraw_i{*}nt :: proc(v: int) {}\n\ndraw :: proc{draw_count}\n",
	)
	// A procedure private to its file cannot join a group in another file.
	expect_no_proc_group(
		t,
		ADD_TO_GROUP,
		"package test\n\n@(private = \"file\")\ndraw_i{*}nt :: proc(v: int) {}\n",
		{{"b.odin", "package test\n\ndraw_str :: proc(s: string) {}\n\ndraw :: proc{draw_str}\n"}},
	)
	expect_no_proc_group(t, MAKE_GROUP, DRAWS, enabled = false)
	expect_no_proc_group(
		t,
		ADD_TO_GROUP,
		"package test\n\ndr{*}aw_int :: proc(v: int) {}\n\ndraw :: proc{}\n",
		enabled = false,
	)
}
