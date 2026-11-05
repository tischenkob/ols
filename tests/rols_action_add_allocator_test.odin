package tests

import "core:strings"
import "core:testing"

import test "src:testing"

@(private = "file")
ADD_ALLOCATOR :: "Add allocator parameter"
@(private = "file")
ADD_LOC :: "Add caller location"

// The harness has no runtime package, so the builtins are declared in the test source.
@(private = "file")
BUILTINS :: `
make :: proc($T: typeid, len: int, allocator := context.allocator, loc := #caller_location) -> T { return {} }
append :: proc(array: ^$T/[dynamic]$E, args: ..E, loc := #caller_location) {}
`

@(private = "file")
allocator_source :: proc(main: string, files: []test.File = {}, enabled := true) -> test.Source {
	return {main = main, files = files, config = {enable_code_action_add_allocator = enabled}}
}

@(private = "file")
expect_no_add_allocator :: proc(t: ^testing.T, title, main: string, files: []test.File = {}, enabled := true) {
	source := allocator_source(main, files, enabled)
	test.expect_action_missing(t, &source, title)
}

@(private = "file")
GROW ::
	`package test

g{*}row :: proc(n: int) -> []int {
	xs := make([]int, n)
	d: [dynamic]int
	append(&d, 1)
	return xs
}
` +
	BUILTINS

// `make` takes an allocator and gains the argument, and `append`, which takes none, stays as it is.
@(test)
add_allocator_passes_it_to_make_and_not_to_append :: proc(t: ^testing.T) {
	source := allocator_source(GROW)
	test.expect_action_applied(
		t,
		&source,
		ADD_ALLOCATOR,
		`package test

grow :: proc(n: int, allocator := context.allocator) -> []int {
	xs := make([]int, n, allocator = allocator)
	d: [dynamic]int
	append(&d, 1)
	return xs
}
` +
		BUILTINS,
	)
}

@(test)
add_caller_location_passes_it_to_make_and_append :: proc(t: ^testing.T) {
	source := allocator_source(GROW)
	test.expect_action_applied(
		t,
		&source,
		ADD_LOC,
		`package test

grow :: proc(n: int, loc := #caller_location) -> []int {
	xs := make([]int, n, loc = loc)
	d: [dynamic]int
	append(&d, 1, loc = loc)
	return xs
}
` +
		BUILTINS,
	)
}

// A caller in another file that has its own allocator passes it, and a caller without one keeps the default.
@(test)
add_allocator_threads_callers_with_an_allocator :: proc(t: ^testing.T) {
	source := allocator_source(
		`package test

g{*}row :: proc(n: int) -> []int {
	return make([]int, n)
}

plain :: proc() {
	_ = grow(1)
}
` +
		BUILTINS,
		{
			{
				"b.odin",
				`package test

import "base:runtime"

build :: proc(n: int, allocator := context.temp_allocator) -> []int {
	return grow(n)
}

typed :: proc(n: int, allocator: runtime.Allocator) -> []int {
	return grow(n)
}
`,
			},
		},
	)
	test.expect_action_applied_files(
		t,
		&source,
		ADD_ALLOCATOR,
		{
			{
				"main.odin",
				`package test

grow :: proc(n: int, allocator := context.allocator) -> []int {
	return make([]int, n, allocator = allocator)
}

plain :: proc() {
	_ = grow(1)
}
` +
				BUILTINS,
			},
			{
				"b.odin",
				`package test

import "base:runtime"

build :: proc(n: int, allocator := context.temp_allocator) -> []int {
	return grow(n, allocator = allocator)
}

typed :: proc(n: int, allocator: runtime.Allocator) -> []int {
	return grow(n, allocator = allocator)
}
`,
			},
		},
	)
}

// A recursive call passes the new parameter on, and a call that already passes an allocator keeps it.
@(test)
add_allocator_passes_it_to_a_recursive_call :: proc(t: ^testing.T) {
	source := allocator_source(
		`package test

g{*}row :: proc(n: int) -> []int {
	if n > 0 {
		_ = grow(n - 1)
	}
	_ = make([]int, n, context.temp_allocator)
	return make([]int, n)
}
` +
		BUILTINS,
	)
	test.expect_action_applied(
		t,
		&source,
		ADD_ALLOCATOR,
		`package test

grow :: proc(n: int, allocator := context.allocator) -> []int {
	if n > 0 {
		_ = grow(n - 1, allocator = allocator)
	}
	_ = make([]int, n, context.temp_allocator)
	return make([]int, n, allocator = allocator)
}
` +
		BUILTINS,
	)
}

@(test)
add_allocator_refuses_unsupported_procedures :: proc(t: ^testing.T) {
	shapes := []string {
		// A contextless or foreign procedure has no context for the default.
		"package test\n\ng{*}row :: proc \"contextless\" (n: int) -> []int {\n\treturn make([]int, n)\n}\n",
		"package test\n\ng{*}row :: proc \"c\" (n: int) -> []int {\n\treturn make([]int, n)\n}\n",
		"package test\n\ng{*}row :: proc(ns: ..int) -> []int {\n\treturn make([]int, len(ns))\n}\n",
		"package test\n\ng{*}row :: proc(n: int, allocator := context.allocator) -> []int {\n\treturn make([]int, n)\n}\n",
		// The name already means a global, which the parameter would hide.
		"package test\n\nallocator := 1\n\ng{*}row :: proc(n: int) -> []int {\n\t_ = allocator\n\treturn make([]int, n)\n}\n",
		// No call in the body takes an allocator, or each one passes its own.
		"package test\n\ng{*}row :: proc(n: int) -> int {\n\treturn n\n}\n",
		"package test\n\ng{*}row :: proc(n: int) -> []int {\n\treturn make([]int, n, allocator = context.temp_allocator)\n}\n",
		// A variable or a value use of the procedure would keep the old type.
		"package test\n\ng{*}row := proc(n: int) -> []int {\n\treturn make([]int, n)\n}\n",
		"package test\n\ng{*}row :: proc(n: int) -> []int {\n\treturn make([]int, n)\n}\n\nkeep := grow\n",
		"package test\n\ng{*}row :: proc(n: int) -> []int {\n\treturn make([]int, n)\n}\n\ngroup :: proc{grow}\n",
		"package test\n\n@(init)\ng{*}row :: proc() {\n\t_ = make([]int, 1)\n}\n",
	}
	for shape in shapes {
		expect_no_add_allocator(t, ADD_ALLOCATOR, strings.concatenate({shape, BUILTINS}, context.temp_allocator))
	}
	expect_no_add_allocator(
		t,
		ADD_LOC,
		"package test\n\ng{*}row :: proc \"contextless\" (n: int) -> []int {\n\treturn make([]int, n)\n}\n" + BUILTINS,
	)
	expect_no_add_allocator(
		t,
		ADD_LOC,
		"package test\n\ng{*}row :: proc(n: int, loc := #caller_location) -> []int {\n\treturn make([]int, n)\n}\n" +
		BUILTINS,
	)
}

// A platform variant would need its own body threaded.
@(test)
add_allocator_refuses_a_platform_variant :: proc(t: ^testing.T) {
	main :=
		"#+build !windows\npackage test\n\ng{*}row :: proc(n: int) -> []int {\n\treturn make([]int, n)\n}\n" + BUILTINS
	variant := "#+build windows\npackage test\n\ngrow :: proc(n: int) -> []int {\n\treturn nil\n}\n"
	expect_no_add_allocator(t, ADD_ALLOCATOR, main, {{"grow_windows.odin", variant}})
}

@(test)
add_allocator_refuses_when_disabled :: proc(t: ^testing.T) {
	expect_no_add_allocator(t, ADD_ALLOCATOR, GROW, enabled = false)
	expect_no_add_allocator(t, ADD_LOC, GROW, enabled = false)
}
