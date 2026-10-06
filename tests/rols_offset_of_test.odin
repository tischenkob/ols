#+feature dynamic-literals

package tests

import "core:testing"

import test "src:testing"

// The member argument of `offset_of(T, member)` names a field of T, never a package, procedure or constant.
@(private = "file")
OFFSET_OF_MAIN :: `package test

import "other"

bar :: 3

S :: struct {
	bar:   int,
	other: int,
}

#assert(offset_of(S, bar) == 0)
#assert(offset_of(S, other) == 8)
#assert(offset_of_member(S, other) == 8)
`

@(private = "file")
other_package :: proc() -> []test.Package {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "other", source = "package other\n\nX :: 1\n"})
	return packages[:]
}

@(test)
offset_of_member_named_like_a_package_keeps_its_arity :: proc(t: ^testing.T) {
	source := test.Source {
		main = OFFSET_OF_MAIN,
		packages = other_package(),
		config = {enable_lint_call_arity = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
offset_of_member_named_like_a_package_is_no_use_of_it :: proc(t: ^testing.T) {
	source := test.Source {
		main     = OFFSET_OF_MAIN,
		packages = other_package(),
	}
	test.expect_unused_imports(t, &source, {"other"})
}

// A struct or bit_field field declared with the name of an import is no use of that import.
@(test)
field_named_like_a_package_is_no_use_of_it :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "other"

S :: struct {
	other: int,
}

B :: bit_field u8 {
	other: u8 | 4,
}
`,
		packages = other_package(),
	}
	test.expect_unused_imports(t, &source, {"other"})
}

@(test)
offset_of_member_follows_a_field_rename :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

bar :: 3

S :: struct {
	b{*}ar: int,
}

#assert(offset_of(S, bar) == 0)
#assert(offset_of_member(S, bar) == 0)
`,
	}
	test.expect_rename(
		t,
		&source,
		"count",
		{
			{
				"main.odin",
				`package test

bar :: 3

S :: struct {
	count: int,
}

#assert(offset_of(S, count) == 0)
#assert(offset_of_member(S, count) == 0)
`,
			},
		},
	)
}

@(test)
offset_of_member_ignores_a_global_rename :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

b{*}ar :: 3

S :: struct {
	bar: int,
}

#assert(offset_of(S, bar) == bar - 3)
`,
	}
	test.expect_rename(
		t,
		&source,
		"three",
		{
			{
				"main.odin",
				`package test

three :: 3

S :: struct {
	bar: int,
}

#assert(offset_of(S, bar) == three - 3)
`,
			},
		},
	)
}

@(test)
offset_of_member_renames_its_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

bar :: 3

S :: struct {
	bar: int,
}

#assert(offset_of(S, b{*}ar) == bar - 3)
`,
	}
	test.expect_rename(
		t,
		&source,
		"count",
		{
			{
				"main.odin",
				`package test

bar :: 3

S :: struct {
	count: int,
}

#assert(offset_of(S, count) == bar - 3)
`,
			},
		},
	)
}

@(test)
offset_of_member_is_a_property_token :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "other"

S :: struct {
	other: int,
}

O :: offset_of(S, other)
`,
		packages = other_package(),
	}
	test.expect_semantic_tokens(
		t,
		&source,
		{
			{2, 8, 5, .Namespace, {}}, // other
			{2, 0, 1, .Struct, {.ReadOnly}}, // S
			{1, 1, 5, .Property, {}}, // other
			{0, 7, 3, .Type, {.ReadOnly}}, // int
			{3, 0, 1, .Variable, {.ReadOnly}}, // O
			{0, 5, 9, .Function, {.ReadOnly}}, // offset_of
			{0, 10, 1, .Struct, {.ReadOnly}}, // S
			{0, 3, 5, .Property, {}}, // the member other
		},
	)
}

@(private = "file")
OFFSET_OF_GLOBAL :: `package test

bar :: 3

S :: struct {
	pad: u8,
	bar: int,
}

#assert(offset_of(S, ba{*}r) == 8)
`

// Hover on the member shows the field of T, not the global of the same name.
@(test)
offset_of_member_hover_shows_the_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = OFFSET_OF_GLOBAL,
	}
	test.expect_hover(t, &source, "S.bar: int")
}

// Go-to-definition on the member goes to the field of T, not to the global of the same name.
@(test)
offset_of_member_definition_goes_to_the_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = OFFSET_OF_GLOBAL,
	}
	test.expect_definition_locations(
		t,
		&source,
		{{range = {start = {line = 6, character = 1}, end = {line = 6, character = 4}}}},
	)
}
