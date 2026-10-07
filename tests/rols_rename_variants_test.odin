package tests

import "core:fmt"
import "core:testing"

import test "src:testing"

// Renaming one branch of a `when` renames the declaration of the other branch, whichever branch holds the cursor.
@(test)
rename_variant_in_other_when_branch :: proc(t: ^testing.T) {
	expected := `package test

when ODIN_DEBUG {
	h :: proc(a: int) -> int { return a }
} else {
	h :: proc(a: int) -> int { return a + 1 }
	k :: proc() -> int { return h(2) }
}

g :: proc() -> int { return h(1) }
`
	for main in ([2]string{`package test

when ODIN_DEBUG {
	f{*} :: proc(a: int) -> int { return a }
} else {
	f :: proc(a: int) -> int { return a + 1 }
	k :: proc() -> int { return f(2) }
}

g :: proc() -> int { return f(1) }
`, `package test

when ODIN_DEBUG {
	f :: proc(a: int) -> int { return a }
} else {
	f{*} :: proc(a: int) -> int { return a + 1 }
	k :: proc() -> int { return f(2) }
}

g :: proc() -> int { return f(1) }
`}) {
		source := test.Source {
			main = main,
		}
		test.expect_rename(t, &source, "h", {{"main.odin", expected}})
	}
}

// A declaration in a file that the build tags keep from the host is a variant of the host's declaration, and the
// references inside that file are renamed with it, whichever file holds the cursor.
@(test)
rename_variant_in_excluded_file :: proc(t: ^testing.T) {
	host := `#+build !windows
package test

f :: proc() -> (v: int, ok: bool) {
	return 1, true
}
`
	excluded := `#+build windows
package test

f :: proc() -> (v: int, ok: bool) {
	return 2, true
}

twice :: proc() -> int {
	v, _ := f()
	return 2 * v
}
`
	use := `package test

g :: proc() -> int {
	v, ok := f()
	if !ok {
		return 0
	}
	return v
}
`
	expected := []test.File {
		{"f_host.odin", `#+build !windows
package test

h :: proc() -> (v: int, ok: bool) {
	return 1, true
}
`},
		{
			"f_windows.odin",
			`#+build windows
package test

h :: proc() -> (v: int, ok: bool) {
	return 2, true
}

twice :: proc() -> int {
	v, _ := h()
	return 2 * v
}
`,
		},
		{"use.odin", `package test

g :: proc() -> int {
	v, ok := h()
	if !ok {
		return 0
	}
	return v
}
`},
	}

	on_host := test.Source {
		files = {
			{
				"f_host.odin",
				"#+build !windows\npackage test\n\nf{*} :: proc() -> (v: int, ok: bool) {\n\treturn 1, true\n}\n",
			},
			{"f_windows.odin", excluded},
			{"use.odin", use},
		},
	}
	test.expect_rename(t, &on_host, "h", expected)

	on_excluded := test.Source {
		files = {
			{
				"f_windows.odin",
				"#+build windows\npackage test\n\nf{*} :: proc() -> (v: int, ok: bool) {\n\treturn 2, true\n}\n\ntwice :: proc() -> int {\n\tv, _ := f()\n\treturn 2 * v\n}\n",
			},
			{"f_host.odin", host},
			{"use.odin", use},
		},
	}
	test.expect_rename(t, &on_excluded, "h", expected)
}

// Two declarations that every build includes together are duplicates, not variants: only the one at the cursor
// is renamed. The same holds for two declarations in one `when` branch.
@(test)
rename_duplicate_is_not_a_variant :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

f{*} :: proc() {}

when ODIN_DEBUG {
	e :: proc() {}
	e :: proc() {}
}
`,
		files = {{"other.odin", `package test

f :: proc() {}
`}},
	}
	test.expect_rename(
		t,
		&source,
		"h",
		{
			{"main.odin", `package test

h :: proc() {}

when ODIN_DEBUG {
	e :: proc() {}
	e :: proc() {}
}
`},
			{"other.odin", `package test

f :: proc() {}
`},
		},
	)
}

// A variant that already declares the new name in its own file is a collision.
@(test)
rename_variant_collision_in_excluded_file :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `#+build !windows
package test

f{*} :: proc() {}
`,
		files = {{"f_windows.odin", `#+build windows
package test

f :: proc() {}
h :: proc() {}
`}},
	}
	test.expect_rename_refused(t, &source, "h", {"`h` is already declared in the package at test/f_windows.odin:5:1"})
}

// Reordering the parameters of one variant reorders every variant and the calls in every file.
@(test)
reorder_params_variants :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

when ODIN_DEBUG {
	f :: proc(a: int, b: string) -> int { return a }
} else {
	f{*} :: proc(a: int, b: string) -> int { return a + 1 }
}

g :: proc() -> int { return f(1, "x") }
`,
		files = {
			{
				"f_windows.odin",
				`#+build windows
package test

f :: proc(a: int, b: string) -> int { return a + 2 }

k :: proc() -> int { return f(2, "y") }
`,
			},
		},
	}
	test.expect_reorder_params(
		t,
		&source,
		{1, 0},
		{
			{
				"main.odin",
				`package test

when ODIN_DEBUG {
	f :: proc(b: string, a: int) -> int { return a }
} else {
	f :: proc(b: string, a: int) -> int { return a + 1 }
}

g :: proc() -> int { return f("x", 1) }
`,
			},
			{
				"f_windows.odin",
				`#+build windows
package test

f :: proc(b: string, a: int) -> int { return a + 2 }

k :: proc() -> int { return f("y", 2) }
`,
			},
		},
	)
}

// Variants whose parameters differ cannot be reordered consistently, so the reorder is refused.
@(test)
reorder_params_refuses_differing_variants :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

when ODIN_DEBUG {
	f :: proc(a: int, b: string) -> int { return a }
} else {
	f{*} :: proc(a: int, b: cstring) -> int { return a + 1 }
}
`,
	}
	test.expect_reorder_params(t, &source, {1, 0}, {})
}

// A file-private declaration is never a variant of one in another file, since each file may declare its own: the
// helper of the windows file keeps its name, by attribute or by `#+private file`.
@(test)
rename_file_private_is_not_a_variant :: proc(t: ^testing.T) {
	windows_files := [2]string {
		`#+build windows
package test

@(private = "file")
helper :: proc() -> int { return 2 }
`,
		`#+build windows
#+private file
package test

helper :: proc() -> int { return 2 }
`,
	}
	for windows in windows_files {
		source := test.Source {
			main  = `package test

@(private = "file")
hel{*}per :: proc() -> int { return 1 }

g :: proc() -> int { return helper() }
`,
			files = {{"b_windows.odin", windows}},
		}
		test.expect_rename(
			t,
			&source,
			"assist",
			{
				{
					"main.odin",
					`package test

@(private = "file")
assist :: proc() -> int { return 1 }

g :: proc() -> int { return assist() }
`,
				},
				{"b_windows.odin", windows},
			},
		)
	}
}

// A field reached through a type that another file declares in an inactive `when` block is renamed in the
// inactive code that uses it. Corpus: tina src/io_types.odin:287, see docs/corpus-validation.md.
@(test)
rename_field_through_inactive_when_type_in_other_file :: proc(t: ^testing.T) {
	sim := `package test

when FLAG {
	Sim :: struct {
		items: [4]S,
	}
}
`
	source := test.Source {
		files = {
			{"s.odin", "package test\n\nFLAG :: #config(FLAG, false)\n\nS :: struct {\n\tf{*}: int,\n}\n"},
			{"sim.odin", sim},
			{
				"main.odin",
				`package test

when FLAG {
	run :: proc(sim: ^Sim) {
		entry := &sim.items[0]
		entry.f = 1
	}
}
`,
			},
		},
	}
	test.expect_rename(
		t,
		&source,
		"g",
		{
			{"s.odin", "package test\n\nFLAG :: #config(FLAG, false)\n\nS :: struct {\n\tg: int,\n}\n"},
			{"sim.odin", sim},
			{
				"main.odin",
				`package test

when FLAG {
	run :: proc(sim: ^Sim) {
		entry := &sim.items[0]
		entry.g = 1
	}
}
`,
			},
		},
	)
}

// A declaration of the new name in another file collides when some target builds that file with the renamed
// declaration or one of its variants. A file-private declaration there does not collide.
@(test)
rename_variant_collision_in_other_file_of_same_target :: proc(t: ^testing.T) {
	renamed := "package test\n\nf{*} :: proc() {}\n"
	variant := "package test\n\nf :: proc() {}\n"
	cases := [?]struct {
		name, text: string,
		causes:     []string,
	} {
		{
			"other_windows.odin",
			"package test\n\nh :: proc() {}\n",
			{"`h` is already declared in the package at test/other_windows.odin:3:1"},
		},
		{"other_linux.odin", "package test\n\nh :: proc() {}\n", {}},
		{"other_windows.odin", "package test\n\n@(private = \"file\")\nh :: proc() {}\n", {}},
	}
	for c in cases {
		source := test.Source {
			files = {{"f_windows.odin", renamed}, {"f_darwin.odin", variant}, {c.name, c.text}},
		}
		test.expect_rename_refused(t, &source, "h", c.causes)
	}
}

// The references of one variant include the other variant and a call that reaches it, whichever holds the cursor.
@(test)
references_include_variants :: proc(t: ^testing.T) {
	for main in ([2]string{`package test

when ODIN_DEBUG {
	f{*} :: proc() -> int { return 1 }
} else {
	f :: proc() -> int { return 2 }
}

g :: proc() -> int { return f() }
`, `package test

when ODIN_DEBUG {
	f :: proc() -> int { return 1 }
} else {
	f{*} :: proc() -> int { return 2 }
}

g :: proc() -> int { return f() }
`}) {
		source := test.Source {
			main = main,
		}
		test.expect_reference_locations(
			t,
			&source,
			{
				{range = {start = {line = 3, character = 1}, end = {line = 3, character = 2}}},
				{range = {start = {line = 5, character = 1}, end = {line = 5, character = 2}}},
				{range = {start = {line = 8, character = 28}, end = {line = 8, character = 29}}},
			},
		)
	}
}

// Renaming a field of one variant of a struct renames the same field of the other variants.
@(test)
rename_field_of_struct_variants :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

when ODIN_DEBUG {
	S :: struct { a: int }
} else {
	S :: struct { a: int, c: int }
}

g :: proc(s: S) -> int { return s.a{*} }
`,
	}
	test.expect_rename(t, &source, "b", {{"main.odin", `package test

when ODIN_DEBUG {
	S :: struct { b: int }
} else {
	S :: struct { b: int, c: int }
}

g :: proc(s: S) -> int { return s.b }
`}})
}

// A field rename through a variant that aliases or embeds the member's type, directly or through another alias,
// renames the member in the other variants too.
@(test)
rename_field_through_alias_or_embedding_variant :: proc(t: ^testing.T) {
	text :: "package test\n\nwhen ODIN_DEBUG {{\n\tS :: struct {{ %s: int }}\n}} else {{\n\t%s\n}}\n\nS_Other :: struct {{ %s: int }}\n\nT :: S_Other\n\ng :: proc(s: S) -> int {{ return s.%s }}\n"
	for variant in ([?]string{"S :: S_Other", "S :: struct { using base: S_Other }", "S :: distinct T"}) {
		source := test.Source {
			main = fmt.tprintf(text, "a", variant, "a", "a{*}"),
		}
		test.expect_rename(t, &source, "b", {{"main.odin", fmt.tprintf(text, "b", variant, "b", "b")}})
	}
}

// The references of a field reached through an alias variant include the member of the other variant.
@(test)
references_of_field_through_alias_variant :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

when ODIN_DEBUG {
	S :: struct { a: int }
} else {
	S :: S_Other
}

S_Other :: struct { a: int }

g :: proc(s: S) -> int { return s.a{*} }
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 3, character = 15}, end = {line = 3, character = 16}}},
			{range = {start = {line = 8, character = 20}, end = {line = 8, character = 21}}},
			{range = {start = {line = 10, character = 34}, end = {line = 10, character = 35}}},
		},
	)
}

// A variant of an alias of the member's type that aliases another type refuses the field rename.
@(test)
rename_field_refused_for_alias_variant_of_other_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

when ODIN_DEBUG {
	S :: S_Third
} else {
	S :: S_Other
}

S_Other :: struct { a: int }
S_Third :: struct { a: int }

g :: proc(s: S) -> int { return s.a{*} }
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"b",
		{
			"the platform variant `S` at test/main.odin:4 is no struct, enum or bit_field type, so its member `a` cannot be renamed",
		},
	)
}

// A member of the new name in another variant of the struct is a collision.
@(test)
rename_field_collision_in_struct_variant :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

when ODIN_DEBUG {
	S :: struct { a: int, c: int }
} else {
	S :: struct { a: int }
}

g :: proc(s: S) -> int { return s.a{*} }
`,
	}
	test.expect_rename_refused(t, &source, "c", {"`c` is already a member of the same type at test/main.odin:4:24"})
}

// A declaration of the new name under a `when` that no target of the renamed declaration's file builds is no
// collision.
@(test)
rename_collision_skips_when_branch_of_other_os :: proc(t: ^testing.T) {
	cases := [?]struct {
		condition: string,
		causes:    []string,
	} {
		{"ODIN_OS == .Linux", {}},
		{"!(ODIN_OS == .Windows) && ODIN_ARCH != .i386", {}},
		{"ODIN_OS == .Windows", {"`h` is already declared in the package at test/b.odin:4:2 (in a when branch)"}},
		{"ODIN_OS == .Linux || FLAG", {"`h` is already declared in the package at test/b.odin:4:2 (in a when branch)"}},
	}
	for c in cases {
		source := test.Source {
			files = {
				{"f.odin", "#+build windows\npackage test\n\nf{*} :: proc() {}\n"},
				{"b.odin", fmt.tprintf("package test\n\nwhen %s {{\n\th :: 1\n}}\n\nFLAG :: true\n", c.condition)},
			},
		}
		test.expect_rename_refused(t, &source, "h", c.causes)
	}
}

// A field rename from a third file, where the type resolves through the index, renames the member in a variant of
// another file.
@(test)
rename_field_of_struct_variant_in_other_file :: proc(t: ^testing.T) {
	source := test.Source {
		files = {
			{"use.odin", "package test\n\ng :: proc(s: S) -> int { return s.a{*} }\n"},
			{"s.odin", "#+build !windows\npackage test\n\nS :: struct { a: int }\n"},
			{"s_windows.odin", "package test\n\nS :: struct { a: int, w: int }\n"},
		},
	}
	test.expect_rename(
		t,
		&source,
		"b",
		{
			{"use.odin", "package test\n\ng :: proc(s: S) -> int { return s.b }\n"},
			{"s.odin", "#+build !windows\npackage test\n\nS :: struct { b: int }\n"},
			{"s_windows.odin", "package test\n\nS :: struct { b: int, w: int }\n"},
		},
	)
}

// Renaming a value of one variant of an enum renames the same value of the other variants.
@(test)
rename_field_of_enum_variants :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

when ODIN_DEBUG {
	E :: enum { A, B }
} else {
	E :: enum { A, C }
}

g :: proc() -> E { return .A{*} }
`,
	}
	test.expect_rename(t, &source, "Z", {{"main.odin", `package test

when ODIN_DEBUG {
	E :: enum { Z, B }
} else {
	E :: enum { Z, C }
}

g :: proc() -> E { return .Z }
`}})
}

// A variant that is an alias, or that may reach the member through `using`, refuses the field rename, since the
// rename cannot change the member there. The cursor resolves through the plain struct of the `else` branch.
@(test)
rename_field_refused_for_unreachable_variant :: proc(t: ^testing.T) {
	cases := [?]struct {
		variant: string,
		cause:   string,
	} {
		{
			"S :: S_Other",
			"the platform variant `S` at test/main.odin:4 is no struct, enum or bit_field type, so its member `a` cannot be renamed",
		},
		{
			"S :: struct { using base: S_Other }",
			"the platform variant `S` at test/main.odin:4 may reach `a` through a `using` field",
		},
		{
			"S :: struct { using _: struct { a: int } }",
			"the platform variant `S` at test/main.odin:4 may reach `a` through a `using` field",
		},
	}
	for c in cases {
		source := test.Source {
			main = fmt.tprintf(
				"package test\n\nwhen ODIN_DEBUG {{\n\t%s\n}} else {{\n\tS :: struct {{ a: int }}\n}}\n\nS_Other :: struct {{ a: int }}\n\ng :: proc(s: S) -> int {{ return s.a{{*}} }}\n",
				c.variant,
			),
		}
		test.expect_rename_refused(t, &source, "b", {c.cause})
	}
}

// A `using` field of another variant of the struct that brings in the new name is a collision.
@(test)
rename_field_collision_through_using_in_struct_variant :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

when ODIN_DEBUG {
	S :: struct { a: int, using base: Base }
} else {
	S :: struct { a: int }
}

Base :: struct { c: int }

g :: proc(s: S) -> int { return s.a{*} }
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"c",
		{"`c` is already a member of the same type through `using base` at test/main.odin:4:30"},
	)
}

// `else when` and nested `when` branches that no target of the renamed declaration's file takes hold no collision.
@(test)
rename_collision_skips_else_and_nested_when_of_other_os :: proc(t: ^testing.T) {
	cases := [?]struct {
		body:   string,
		causes: []string,
	} {
		{"when ODIN_OS == .Windows {\n} else when ODIN_ARCH == .amd64 {\n\th :: 1\n}\n", {}},
		{
			"when ODIN_OS == .Linux {\n} else when ODIN_ARCH == .amd64 {\n\th :: 1\n}\n",
			{"`h` is already declared in the package at test/b.odin:5:2 (in a when branch)"},
		},
		{"when ODIN_ARCH == .amd64 {\n\twhen ODIN_OS == .Linux {\n\t\th :: 1\n\t}\n}\n", {}},
		{
			"when ODIN_ARCH == .amd64 {\n\twhen ODIN_OS == .Windows {\n\t\th :: 1\n\t}\n}\n",
			{"`h` is already declared in the package at test/b.odin:5:3 (in a when branch)"},
		},
	}
	for c in cases {
		source := test.Source {
			files = {
				{"f.odin", "#+build windows\npackage test\n\nf{*} :: proc() {}\n"},
				{"b.odin", fmt.tprintf("package test\n\n%s", c.body)},
			},
		}
		test.expect_rename_refused(t, &source, "h", c.causes)
	}
}

// A declaration of the new name that the index holds, in a `when` branch the host takes but no target of the
// renamed declaration's file does, is no collision.
@(test)
rename_collision_skips_index_hit_in_when_of_other_os :: proc(t: ^testing.T) {
	source := test.Source {
		files = {
			{"f.odin", "#+build windows\npackage test\n\nf{*} :: proc() {}\n"},
			{"b.odin", "package test\n\nwhen ODIN_OS != .Windows {\n\th :: 1\n}\n"},
		},
	}
	test.expect_rename_refused(t, &source, "h", {})
}
