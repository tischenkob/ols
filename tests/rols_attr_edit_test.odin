package tests

import "core:testing"

import test "src:testing"

@(test)
attr_add_into_last_group :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n@(private) @(link_name=\"y\") y{*} := 1\n",
	}
	test.expect_attr_edit(
		t,
		&source,
		.Add,
		{"rodata"},
		{{"main.odin", "package test\n\n@(private) @(link_name=\"y\", rodata) y := 1\n"}},
	)
}

@(test)
attr_add_rewrites_bare_form :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n@private x{*} :: 0\n",
	}
	test.expect_attr_edit(t, &source, .Add, {"rodata"}, {{"main.odin", "package test\n\n@(private, rodata) x :: 0\n"}})
}

// The new line takes the indentation of a declaration inside a `when` block in a procedure body.
@(test)
attr_add_new_line_indented :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	when ODIN_DEBUG {
		counter{*}: int
		counter += 1
	}
}
`,
	}
	test.expect_attr_edit(
		t,
		&source,
		.Add,
		{"static"},
		{
			{
				"main.odin",
				`package test

main :: proc() {
	when ODIN_DEBUG {
		@(static)
		counter: int
		counter += 1
	}
}
`,
			},
		},
	)
}

@(test)
attr_add_value_new_line :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n// Doc.\nf{*} :: proc() {}\n",
	}
	test.expect_attr_edit(
		t,
		&source,
		.Add,
		{`link_name = "g"`},
		{{"main.odin", "package test\n\n// Doc.\n@(link_name=\"g\")\nf :: proc() {}\n"}},
	)
}

@(test)
attr_add_present_key_refused :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n@(private)\n@(rodata) z{*} := 1\n",
	}
	test.expect_attr_refused(
		t,
		&source,
		.Add,
		{"private"},
		{"main.odin:3:3: the declaration already has the attribute `private`"},
	)
}

@(test)
attr_add_unparsable_value_refused :: proc(t: ^testing.T) {
	cases := [?]string{`link_name="a" b`, `link_name=1) y :: 2 @(z`, `link_name="a", rodata`, "link_name="}
	for spec in cases {
		source := test.Source {
			main = "package test\n\nf{*} :: proc() {}\n",
		}
		test.expect_attr_refused(t, &source, .Add, {spec}, {"is not an Odin expression"})
	}
}

@(test)
attr_add_struct_field_refused :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\nS :: struct {\n\tf{*}: int,\n}\n",
	}
	test.expect_attr_refused(t, &source, .Add, {"private"}, {"`f` is a member of a struct, enum or bit_field type"})
}

@(test)
attr_invalid_identifiers_refused :: proc(t: ^testing.T) {
	{
		source := test.Source {
			main = "package test\n\nf{*} :: proc() {}\n",
		}
		test.expect_attr_refused(t, &source, .Add, {"1x"}, {"`1x` is not a valid Odin identifier"})
	}
	{
		source := test.Source {
			main = "package test\n\n@(private) f{*} :: proc() {}\n",
		}
		test.expect_attr_refused(t, &source, .Remove, {"a-b"}, {"`a-b` is not a valid Odin identifier"})
	}
	{
		source := test.Source {
			main = "package test\n\n@(private) f :: proc() {}\n",
		}
		test.expect_attr_refused(t, &source, .Rename, {"private", "proc", ""}, {"`proc` is a keyword"})
	}
	{
		source := test.Source {
			main = "package test\n\n@(private) f :: proc() {}\n",
		}
		test.expect_attr_refused(
			t,
			&source,
			.Remove_All,
			{"pri vate", ""},
			{"`pri vate` is not a valid Odin identifier"},
		)
	}
}

@(test)
attr_remove_group_on_own_line :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n@(private)\nx{*} :: 0\n",
	}
	test.expect_attr_edit(t, &source, .Remove, {"private"}, {{"main.odin", "package test\n\nx :: 0\n"}})
}

@(test)
attr_remove_group_on_declaration_line :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n@(private) @(rodata) x{*} := 0\n",
	}
	test.expect_attr_edit(t, &source, .Remove, {"private"}, {{"main.odin", "package test\n\n@(rodata) x := 0\n"}})
}

@(test)
attr_remove_from_group :: proc(t: ^testing.T) {
	{
		source := test.Source {
			main = "package test\n\n@(private, link_name=\"y\", rodata) y{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"link_name"},
			{{"main.odin", "package test\n\n@(private, rodata) y := 1\n"}},
		)
	}
	{
		source := test.Source {
			main = "package test\n\n@(\n\tprivate,\n\trodata,\n)\ny{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"rodata"},
			{{"main.odin", "package test\n\n@(\n\tprivate,\n)\ny := 1\n"}},
		)
	}
}

@(test)
attr_remove_bare_form :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n@private\tx{*} :: 0\n",
	}
	test.expect_attr_edit(t, &source, .Remove, {"private"}, {{"main.odin", "package test\n\nx :: 0\n"}})
}

@(test)
attr_remove_missing_key_noop :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n@(private) x{*} :: 0\n",
	}
	test.expect_attr_edit(t, &source, .Remove, {"rodata"}, {})
}

// Foreign imports, foreign blocks and their members, `when` blocks and procedure bodies, in two files.
@(test)
attr_remove_all_across_files :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

@(private)
foreign import lib "system:c"

@(private)
foreign lib {
	@(private, link_name = "puts") put :: proc(s: cstring) -> i32 ---
}

when ODIN_OS == .Darwin {
	@(rodata, private)
	table := [2]int{1, 2}
}
`,
		files = {
			{
				"other.odin",
				"package test\n\n@private helper :: proc() {}\n\nmain :: proc() {\n\t@(private) inner :: 1\n\t_ = inner\n}\n",
			},
		},
	}
	test.expect_attr_edit(
		t,
		&source,
		.Remove_All,
		{"private", ""},
		{
			{
				"main.odin",
				`package test

foreign import lib "system:c"

foreign lib {
	@(link_name = "puts") put :: proc(s: cstring) -> i32 ---
}

when ODIN_OS == .Darwin {
	@(rodata)
	table := [2]int{1, 2}
}
`,
			},
			{"other.odin", "package test\n\nhelper :: proc() {}\n\nmain :: proc() {\n\tinner :: 1\n\t_ = inner\n}\n"},
		},
	)
}

// The value stays, and DIR limits the rename to its package.
@(test)
attr_rename_keeps_value :: proc(t: ^testing.T) {
	source := test.Source {
		main     = "package test\n\n@(private=\"file\") x :: 0\n",
		packages = {{pkg = "pkg", source = "package pkg\n\n@(private = \"file\", rodata) Y := 1\n"}},
	}
	test.expect_attr_edit(
		t,
		&source,
		.Rename,
		{"private", "hidden", "pkg"},
		{
			{"main.odin", "package test\n\n@(private=\"file\") x :: 0\n"},
			{"pkg/package.odin", "package pkg\n\n@(hidden = \"file\", rodata) Y := 1\n"},
		},
	)
}

@(test)
attr_rename_existing_key_refused :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n@(private, rodata) x := 1\n\n@(private) y := 2\n\n@(rodata)\n@(private) z := 3\n",
	}
	test.expect_attr_refused(
		t,
		&source,
		.Rename,
		{"private", "rodata", ""},
		{
			"main.odin:3:3: the declaration already has `rodata`, so renaming `private` would duplicate it",
			"main.odin:8:3: the declaration already has `rodata`",
		},
	)
}

// The comments of a kept element stay; a removed element takes its own.
@(test)
attr_remove_trailing_run_keeps_comments :: proc(t: ^testing.T) {
	{
		source := test.Source {
			main = "package test\n\n@(\n\tprivate, // keep\n\trodata, // why\n)\ny{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"rodata"},
			{{"main.odin", "package test\n\n@(\n\tprivate, // keep\n)\ny := 1\n"}},
		)
	}
	{
		source := test.Source {
			main = "package test\n\n@(private /* A */, rodata /* B */) y{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"rodata"},
			{{"main.odin", "package test\n\n@(private /* A */) y := 1\n"}},
		)
	}
	{
		source := test.Source {
			main = "package test\n\n@(private /* A */, rodata /* B */, link_name=\"y\") y{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"rodata"},
			{{"main.odin", "package test\n\n@(private /* A */, link_name=\"y\") y := 1\n"}},
		)
	}
	{
		source := test.Source {
			main = "package test\n\n@(\n\tprivate, // keep\n\trodata // why\n)\ny{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"rodata"},
			{{"main.odin", "package test\n\n@(\n\tprivate, // keep\n)\ny := 1\n"}},
		)
	}
	// A comment before the next kept element stays, on its own line or inline.
	{
		source := test.Source {
			main = "package test\n\n@(\n\tprivate,\n\t// why rodata\n\trodata,\n)\ny{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"private"},
			{{"main.odin", "package test\n\n@(\n\t// why rodata\n\trodata,\n)\ny := 1\n"}},
		)
	}
	{
		source := test.Source {
			main = "package test\n\n@(private, /* r */ rodata) y{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"private"},
			{{"main.odin", "package test\n\n@(/* r */ rodata) y := 1\n"}},
		)
	}
	// A removed element's comment on its line goes with it.
	{
		source := test.Source {
			main = "package test\n\n@(\n\tprivate, // why private\n\trodata,\n)\ny{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"private"},
			{{"main.odin", "package test\n\n@(\n\trodata,\n)\ny := 1\n"}},
		)
	}
	// A block comment that spans a line stays whole.
	{
		source := test.Source {
			main = "package test\n\n@(\n\tprivate, /* long\n\t   note */ rodata,\n)\ny{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"private"},
			{{"main.odin", "package test\n\n@(\n\t/* long\n\t   note */ rodata,\n)\ny := 1\n"}},
		)
	}
	// A run after code on its line goes from the comma before it to the end of its line.
	with_comment := "package test\n\n@(rodata, private, // why private\n\tlink_name=\"y\") y{*} := 1\n"
	bare := "package test\n\n@(rodata, private,\n\tlink_name=\"y\") y{*} := 1\n"
	for main in ([]string{with_comment, bare}) {
		source := test.Source {
			main = main,
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"private"},
			{{"main.odin", "package test\n\n@(rodata,\n\tlink_name=\"y\") y := 1\n"}},
		)
	}
	// `)` on the removed element's line keeps that line's indentation.
	{
		source := test.Source {
			main = "package test\n\n@(\n\tprivate,\n\trodata)\ny{*} := 1\n",
		}
		test.expect_attr_edit(
			t,
			&source,
			.Remove,
			{"rodata"},
			{{"main.odin", "package test\n\n@(\n\tprivate,\n\t)\ny := 1\n"}},
		)
	}
}

@(test)
attr_remove_crlf_line :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\r\n\r\n@(private)\r\nx{*} :: 0\r\n",
	}
	test.expect_attr_edit(t, &source, .Remove, {"private"}, {{"main.odin", "package test\r\n\r\nx :: 0\r\n"}})
}

@(test)
attr_add_into_empty_group :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\n@() x{*} :: 0\n",
	}
	test.expect_attr_edit(t, &source, .Add, {"private"}, {{"main.odin", "package test\n\n@(private) x :: 0\n"}})
}

@(test)
attr_add_inline_after_code :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\nwhen ODIN_DEBUG { x{*} :: 0 }\n",
	}
	test.expect_attr_edit(
		t,
		&source,
		.Add,
		{"private"},
		{{"main.odin", "package test\n\nwhen ODIN_DEBUG { @(private) x :: 0 }\n"}},
	)
}

// A value declaration without values has a head that spans its type, members included.
@(test)
attr_add_member_of_declared_type_refused :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\nx: struct {\n\tf{*}: int,\n}\n",
	}
	test.expect_attr_refused(t, &source, .Add, {"private"}, {"`f` is a member of a struct, enum or bit_field type"})
}
