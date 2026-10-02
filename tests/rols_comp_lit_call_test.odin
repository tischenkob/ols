package tests

import "core:testing"

import test "src:testing"

COMP_LIT_CALL_PACKAGE :: `package my_package

BufferUsage :: distinct u32

BufferCreateInfo :: struct {
	usage: BufferUsage,
	size:  u32,
}

Device :: struct {}
Buffer :: struct {}

foreign _ {
	CreateBuffer :: proc(device: ^Device, #by_ptr createinfo: BufferCreateInfo) -> ^Buffer ---
}
`

@(test)
ast_completion_comp_lit_call_inside_struct_literal :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "my_package", source = COMP_LIT_CALL_PACKAGE})
	source := test.Source {
		main     = `package test
		import "my_package"

		State :: struct {
			device: ^my_package.Device,
			buffer: ^my_package.Buffer,
		}

		main :: proc() {
			device: ^my_package.Device
			state := State{buffer = my_package.CreateBuffer(device, { {*} })}
		}
		`,
		packages = packages[:],
	}
	test.expect_completion_docs(
		t,
		&source,
		"",
		{"BufferCreateInfo.usage: my_package.BufferUsage", "BufferCreateInfo.size: u32"},
		{"State.device: ^my_package.Device", "State.buffer: ^my_package.Buffer"},
	)
}

@(test)
ast_completion_comp_lit_call_inside_array_literal :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "my_package", source = COMP_LIT_CALL_PACKAGE})
	source := test.Source {
		main     = `package test
		import "my_package"

		main :: proc() {
			device: ^my_package.Device
			buffers := []^my_package.Buffer{my_package.CreateBuffer(device, { {*} })}
		}
		`,
		packages = packages[:],
	}
	test.expect_completion_docs(
		t,
		&source,
		"",
		{"BufferCreateInfo.usage: my_package.BufferUsage", "BufferCreateInfo.size: u32"},
	)
}

@(test)
ast_completion_comp_lit_package_call_second_arg :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "my_package", source = COMP_LIT_CALL_PACKAGE})
	source := test.Source {
		main     = `package test
		import "my_package"

		main :: proc() {
			device: ^my_package.Device
			my_package.CreateBuffer(device, { {*} })
		}
		`,
		packages = packages[:],
	}
	test.expect_completion_docs(
		t,
		&source,
		"",
		{"BufferCreateInfo.usage: my_package.BufferUsage", "BufferCreateInfo.size: u32"},
	)
}

@(test)
reference_comp_lit_field_in_call_inside_struct_literal :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Info :: struct {
			s{*}ize: int,
		}
		Holder :: struct {
			size: int,
			n:    int,
		}
		make_n :: proc(info: Info) -> int { return 0 }
		main :: proc() {
			h := Holder{n = make_n({size = 4})}
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 3}, end = {line = 2, character = 7}}},
			{range = {start = {line = 10, character = 27}, end = {line = 10, character = 31}}},
		},
	)
}

@(test)
reference_named_arg_after_comp_lit_arg :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		S :: struct {
			a: int,
		}
		f :: proc(s: S, i{*}nfo: int) {}
		main :: proc() {
			f(S{a = 1}, info = 2)
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 4, character = 18}, end = {line = 4, character = 22}}},
			{range = {start = {line = 6, character = 15}, end = {line = 6, character = 19}}},
		},
	)
}
