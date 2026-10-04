#+feature dynamic-literals

package tests

import "core:testing"

import test "src:testing"

@(private = "file")
TITLE :: "Change result type to returned types"

@(private = "file")
packages :: proc() -> []test.Package {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(
		&packages,
		test.Package{pkg = "runtime", source = `package runtime
Allocator_Error :: enum u8 { None, Out_Of_Memory }
`},
	)
	append(
		&packages,
		test.Package {
			pkg = "os",
			source = `package os
import base "core:runtime"
General_Error :: enum u32 { None, Exist }
Error :: union #shared_nil { General_Error, base.Allocator_Error }
read :: proc(path: string) -> (data: []byte, err: Error) { return nil, nil }
wait :: proc() -> bool { return true }
load :: proc(name: string) -> (int, union {base.Allocator_Error, Error}) { return 0, nil }
pick :: proc(x: $T) -> (T, bool) { return x, true }
File :: struct { fd: int }
Handle :: distinct int
file :: proc() -> ^File { return nil }
files :: proc() -> []File { return nil }
bytes :: proc() -> []byte { return nil }
handle :: proc() -> Handle { return 0 }
load_shared :: proc() -> (int, union #shared_nil {base.Allocator_Error, Error}) { return 0, nil }
write_int :: proc(x: int) -> bool { return true }
write_string :: proc(x: string) -> bool { return true }
write :: proc {write_int, write_string}
join :: proc(a: string) -> (string, base.Allocator_Error) { return a, nil }
pair :: proc() -> (int, Error) { return 0, nil }
triple :: proc() -> (int, bool, Error) { return 0, true, nil }
`,
		},
	)
	return packages[:]
}

@(private = "file")
expect_result_union :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main = main,
		packages = packages(),
		collections = {"core" = "test"},
		config = {enable_code_action_result_union = true},
	}
	test.expect_action_applied(t, &source, TITLE, expected)
}

@(private = "file")
expect_result_union_files :: proc(t: ^testing.T, main: string, files: []test.File, expected: string) {
	source := test.Source {
		main = main,
		files = files,
		packages = packages(),
		collections = {"core" = "test"},
		config = {enable_code_action_result_union = true},
	}
	test.expect_action_applied(t, &source, TITLE, expected)
}

@(private = "file")
expect_no_result_union :: proc(t: ^testing.T, main: string, enabled := true) {
	source := test.Source {
		main = main,
		packages = packages(),
		collections = {"core" = "test"},
		config = {enable_code_action_result_union = enabled},
	}
	test.expect_action_missing(t, &source, TITLE)
}

@(test)
result_union_mixed :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> int {
	os.wait() or_return
	data := os.read("x") or_return
	if flag {
		re{*}turn true
	}
	return 1
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> union {bool, os.Error, int} {
	os.wait() or_return
	data := os.read("x") or_return
	if flag {
		return true
	}
	return 1
}
`,
	)
}

@(test)
result_union_single_type :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	os.wa{*}it() or_return
	return true
}
`,
		`package test

import "core:os"

run :: proc() -> bool {
	os.wait() or_return
	return true
}
`,
	)
}

@(test)
result_union_named_result :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (err: int) {
	os.wa{*}it() or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (err: bool) {
	os.wait() or_return
	return
}
`,
	)
}

@(test)
result_union_bool_local_from_other_package :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	ok := os.wait()
	ret{*}urn ok
}
`,
		`package test

import "core:os"

run :: proc() -> bool {
	ok := os.wait()
	return ok
}
`,
	)
}

@(test)
result_union_anonymous_union_requalified :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"
import rt "core:runtime"

run :: proc() -> bool {
	n := os.lo{*}ad("a") or_return
	return true
}
`,
		`package test

import "core:os"
import rt "core:runtime"

run :: proc() -> union {union {rt.Allocator_Error, os.Error}, bool} {
	n := os.load("a") or_return
	return true
}
`,
	)
}

@(test)
result_union_adds_import :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> bool {
	n := os.lo{*}ad("a") or_return
	return true
}
`,
		`package test
import "core:runtime"

import "core:os"

run :: proc() -> union {union {runtime.Allocator_Error, os.Error}, bool} {
	n := os.load("a") or_return
	return true
}
`,
	)
}

@(test)
result_union_same_file_callee :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"
import rt "core:runtime"

load_shader :: proc(name: string) -> (shader: int, err: union {rt.Allocator_Error, os.Error}) {
	return 0, nil
}

run :: proc() -> union {bool, any} {
	os.wait() or_return
	shader := load_shader("a") or{*}_return
	return true
}
`,
		`package test

import "core:os"
import rt "core:runtime"

load_shader :: proc(name: string) -> (shader: int, err: union {rt.Allocator_Error, os.Error}) {
	return 0, nil
}

run :: proc() -> union {bool, union {rt.Allocator_Error, os.Error}} {
	os.wait() or_return
	shader := load_shader("a") or_return
	return true
}
`,
	)
}

@(test)
result_union_ignores_nil_and_implicit_selector :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> os.General_Error {
	if flag {
		return nil
	}
	if !flag {
		return .Exist
	}
	os.re{*}ad("x") or_return
	return {}
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> os.Error {
	if flag {
		return nil
	}
	if !flag {
		return .Exist
	}
	os.read("x") or_return
	return {}
}
`,
	)
}

@(test)
result_union_skips_nested_proc :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	helper := proc() -> int {
		return "x"
	}
	os.wa{*}it() or_return
	return 0
}
`,
		`package test

import "core:os"

run :: proc() -> union {bool, int} {
	helper := proc() -> int {
		return "x"
	}
	os.wait() or_return
	return 0
}
`,
	)
}

@(test)
result_union_nested_proc_return :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	helper := proc() -> int {
		re{*}turn "x"
	}
	os.wait() or_return
	return 0
}
`,
		`package test

import "core:os"

run :: proc() -> int {
	helper := proc() -> string {
		return "x"
	}
	os.wait() or_return
	return 0
}
`,
	)
}

@(test)
result_union_unresolved_return :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	os.wa{*}it() or_return
	return missing()
}
`,
	)
}

@(test)
result_union_generic_result :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	v := os.pi{*}ck(1) or_return
	return v
}
`,
	)
}

@(test)
result_union_cursor_elsewhere :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> i{*}nt {
	os.wait() or_return
	return true
}
`,
	)
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	x{*} := 1
	os.wait() or_return
	return true
}
`,
	)
}

@(test)
result_union_declared_type_matches :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> union{bool,os.Error} {
	os.wait() or_return
	os.read("x") or_return
	ret{*}urn true
}
`,
	)
}

@(test)
result_union_multiple_results :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

Shader :: struct {}

load :: proc(name: string) -> (^Shader, union {}) {
	path := os.join(name) or_return
	data := os.re{*}ad(path) or_return
	shader: ^Shader
	return shader
}
`,
		`package test
import "core:runtime"

import "core:os"

Shader :: struct {}

load :: proc(name: string) -> (shader2: ^Shader, err: union {runtime.Allocator_Error, os.Error}) {
	path := os.join(name) or_return
	data := os.read(path) or_return
	shader: ^Shader
	return shader
}
`,
	)
}

@(test)
result_union_disabled :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	os.wa{*}it() or_return
	return true
}
`,
		false,
	)
}

@(test)
result_union_typed_local_slice :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

run :: proc() -> int {
	data: []byte
	ret{*}urn data
}
`,
		`package test

run :: proc() -> []byte {
	data: []byte
	return data
}
`,
	)
}

@(test)
result_union_typed_local_anonymous_struct :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

run :: proc() -> int {
	x: struct { a: int }
	ret{*}urn x
}
`,
		`package test

run :: proc() -> struct {a: int} {
	x: struct { a: int }
	return x
}
`,
	)
}

@(test)
result_union_parameter_type :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(data: []os.File) -> int {
	ret{*}urn data
}
`,
		`package test

import "core:os"

run :: proc(data: []os.File) -> []os.File {
	return data
}
`,
	)
}

@(test)
result_union_anonymous_field_selector :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

S :: struct { inner: struct { a: int } }

run :: proc() -> int {
	s: S
	ret{*}urn s.inner
}
`,
	)
}

@(test)
result_union_inferred_anonymous_local :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	data := os.bytes()
	ret{*}urn data
}
`,
	)
}

@(test)
result_union_inferred_named_local :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	h := os.handle()
	ret{*}urn h
}
`,
		`package test

import "core:os"

run :: proc() -> os.Handle {
	h := os.handle()
	return h
}
`,
	)
}

@(test)
result_union_untyped_constant_fits :: proc(t: ^testing.T) {
	expect_no_result_union(t, `package test

run :: proc() -> f32 {
	ret{*}urn 1
}
`)
	expect_no_result_union(t, `package test

run :: proc() -> cstring {
	ret{*}urn "x"
}
`)
	expect_no_result_union(t, `package test

run :: proc() -> u8 {
	ret{*}urn 0
}
`)
	expect_no_result_union(t, `package test

My_Float :: distinct f32

run :: proc() -> My_Float {
	ret{*}urn 1.5
}
`)
}

@(test)
result_union_untyped_constant_mixed :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> f32 {
	if flag {
		ret{*}urn 1
	}
	return os.wait()
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> union {f32, bool} {
	if flag {
		return 1
	}
	return os.wait()
}
`,
	)
}

@(test)
result_union_untyped_constant_union_variant :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> union {bool, f32} {
	if flag {
		ret{*}urn 1
	}
	os.read("x") or_return
	return true
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> union {f32, os.Error, bool} {
	if flag {
		return 1
	}
	os.read("x") or_return
	return true
}
`,
	)
}

@(test)
result_union_untyped_variable :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

run :: proc() -> f32 {
	x := 1
	ret{*}urn x
}
`,
		`package test

run :: proc() -> int {
	x := 1
	return x
}
`,
	)
}

@(test)
result_union_import_alias_taken_by_param :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc(runtime: int) -> bool {
	n := os.lo{*}ad("a") or_return
	return true
}
`,
	)
}

@(test)
result_union_proc_group :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> int {
	os.wr{*}ite(1) or_return
	return 0
}
`,
	)
	expect_no_result_union(
		t,
		`package test

put_int :: proc(x: int) -> bool { return true }
put_string :: proc(x: string) -> bool { return true }
put :: proc {put_int, put_string}

run :: proc() -> int {
	pu{*}t(1) or_return
	return 0
}
`,
	)
}

@(test)
result_union_keeps_union_directive :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"
import rt "core:runtime"

run :: proc() -> int {
	n := os.load_{*}shared() or_return
	return n
}
`,
		`package test

import "core:os"
import rt "core:runtime"

run :: proc() -> union {union #shared_nil {rt.Allocator_Error, os.Error}, int} {
	n := os.load_shared() or_return
	return n
}
`,
	)
}

@(test)
result_union_pointer_and_slice :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> int {
	if flag {
		ret{*}urn os.file()
	}
	return os.files()
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> union {^os.File, []os.File} {
	if flag {
		return os.file()
	}
	return os.files()
}
`,
	)
}

@(test)
result_union_same_package_other_file :: proc(t: ^testing.T) {
	expect_result_union_files(
		t,
		`package test

import "core:os"
import rt "core:runtime"

run :: proc() -> int {
	n := hel{*}per() or_return
	return 0
}
`,
		{
			{
				"other.odin",
				`package test

import base "core:runtime"
import sys "core:os"

helper :: proc() -> (int, union #no_nil {base.Allocator_Error, sys.General_Error}) { return 0, nil }
`,
			},
		},
		`package test

import "core:os"
import rt "core:runtime"

run :: proc() -> union {union #no_nil {rt.Allocator_Error, os.General_Error}, int} {
	n := helper() or_return
	return 0
}
`,
	)
}

@(test)
result_union_body_local_type :: proc(t: ^testing.T) {
	expect_no_result_union(t, `package test

run :: proc() -> int {
	Foo :: struct { a: int }
	x: Foo
	ret{*}urn x
}
`)
}

@(test)
result_union_body_local_array_length :: proc(t: ^testing.T) {
	expect_no_result_union(t, `package test

run :: proc() -> int {
	N :: 4
	x: [N]int
	ret{*}urn x
}
`)
}

@(test)
result_union_body_local_callee_type :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

run :: proc() -> int {
	Foo :: struct { a: int }
	helper := proc() -> Foo { return {} }
	ret{*}urn helper()
}
`,
	)
}

@(test)
result_union_nested_uses_outer_local_type :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

run :: proc() -> int {
	Foo :: struct { a: int }
	helper :: proc() -> int {
		x: Foo
		ret{*}urn x
	}
	return 0
}
`,
		`package test

run :: proc() -> int {
	Foo :: struct { a: int }
	helper :: proc() -> Foo {
		x: Foo
		return x
	}
	return 0
}
`,
	)
}

@(test)
result_union_poly_union_constant :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

Maybe :: union($T: typeid) {T}

run :: proc() -> Maybe(int) {
	ret{*}urn 1
}
`,
	)
}

@(test)
result_union_poly_union_struct :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

Maybe :: union($T: typeid) {T}
My_Struct :: struct { a: int }

run :: proc(flag: bool) -> Maybe(My_Struct) {
	os.wait() or_return
	ret{*}urn true
}
`,
		`package test

import "core:os"

Maybe :: union($T: typeid) {T}
My_Struct :: struct { a: int }

run :: proc(flag: bool) -> bool {
	os.wait() or_return
	return true
}
`,
	)
}

@(test)
result_union_type_as_value :: proc(t: ^testing.T) {
	expect_no_result_union(t, `package test

run :: proc() -> typeid {
	ret{*}urn int
}
`)
	expect_no_result_union(t, `package test

import "core:os"

run :: proc() -> typeid {
	ret{*}urn os.Error
}
`)
	expect_no_result_union(t, `package test

run :: proc() -> typeid {
	ret{*}urn []int
}
`)
}

@(test)
result_union_named_result_value :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (res: []os.File) {
	os.wa{*}it() or_return
	return res
}
`,
		`package test

import "core:os"

run :: proc() -> (res: bool) {
	os.wait() or_return
	return res
}
`,
	)
}

@(test)
result_union_named_union_constant_mixed :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

Number :: union { int, bool }

run :: proc(flag: bool) -> Number {
	os.wait() or_return
	ret{*}urn 1
}
`,
	)
}

@(test)
result_union_nil_needs_nilable_type :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

Maybe :: union($T: typeid) {T}

run :: proc(flag: bool) -> Maybe(int) {
	if flag {
		return nil
	}
	return os.wa{*}it()
}
`,
	)
}

@(test)
result_union_nil_with_pointer :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> int {
	if flag {
		return nil
	}
	return os.fi{*}le()
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> ^os.File {
	if flag {
		return nil
	}
	return os.file()
}
`,
	)
}

@(test)
result_union_nil_with_named_union :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> int {
	if flag {
		return nil
	}
	os.re{*}ad("x") or_return
	return nil
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> os.Error {
	if flag {
		return nil
	}
	os.read("x") or_return
	return nil
}
`,
	)
}

@(test)
result_union_nil_with_generated_union :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> int {
	if flag {
		return nil
	}
	os.wa{*}it() or_return
	return 1.5
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> union {bool, f64} {
	if flag {
		return nil
	}
	os.wait() or_return
	return 1.5
}
`,
	)
}

@(test)
result_union_constant_ambiguous :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

run :: proc(flag: bool) -> i32 {
	x: u32
	if flag {
		return x
	}
	ret{*}urn 0
}
`,
	)
	expect_no_result_union(
		t,
		`package test

run :: proc(flag: bool) -> f32 {
	x: f64
	if flag {
		return x
	}
	ret{*}urn 1
}
`,
	)
	expect_no_result_union(
		t,
		`package test

run :: proc(flag: bool) -> b8 {
	x: b32
	if flag {
		return x
	}
	ret{*}urn true
}
`,
	)
}

@(test)
result_union_constant_default_type_wins :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

run :: proc(flag: bool) -> i32 {
	x: int
	if flag {
		return x
	}
	ret{*}urn 0
}
`,
		`package test

run :: proc(flag: bool) -> union {int, i32} {
	x: int
	if flag {
		return x
	}
	return 0
}
`,
	)
}

@(test)
result_union_constant_same_family_wins :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

run :: proc(flag: bool) -> f32 {
	x: i32
	if flag {
		return x
	}
	ret{*}urn 1
}
`,
		`package test

run :: proc(flag: bool) -> union {i32, f32} {
	x: i32
	if flag {
		return x
	}
	return 1
}
`,
	)
}

@(test)
result_union_constant_distinct_type :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> os.Handle {
	x: i32
	if flag {
		return x
	}
	ret{*}urn 0
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> union {i32, os.Handle} {
	x: i32
	if flag {
		return x
	}
	return 0
}
`,
	)
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> os.Handle {
	x: int
	if flag {
		return x
	}
	ret{*}urn 0
}
`,
	)
}

@(test)
result_union_constant_rune_family :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

run :: proc(flag: bool) -> rune {
	x: i32
	if flag {
		return x
	}
	ret{*}urn 1
}
`,
	)
	expect_no_result_union(
		t,
		`package test

run :: proc(flag: bool) -> i32 {
	x: u8
	if flag {
		return x
	}
	ret{*}urn 'a'
}
`,
	)
	expect_result_union(
		t,
		`package test

run :: proc(flag: bool) -> rune {
	x: i32
	if flag {
		return x
	}
	ret{*}urn 'a'
}
`,
		`package test

run :: proc(flag: bool) -> union {i32, rune} {
	x: i32
	if flag {
		return x
	}
	return 'a'
}
`,
	)
}

@(test)
result_union_constant_integral_float :: proc(t: ^testing.T) {
	expect_no_result_union(t, `package test

run :: proc() -> int {
	ret{*}urn 1.0
}
`)
	expect_result_union(
		t,
		`package test

run :: proc() -> int {
	ret{*}urn 1.5
}
`,
		`package test

run :: proc() -> f64 {
	return 1.5
}
`,
	)
	expect_no_result_union(
		t,
		`package test

run :: proc(flag: bool) -> i32 {
	x: u8
	if flag {
		return x
	}
	ret{*}urn 1.0
}
`,
	)
	expect_no_result_union(t, `package test

HALF :: 0.5

run :: proc(flag: bool) -> int {
	ret{*}urn HALF
}
`)
}

@(test)
result_union_constant_best_variant :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> union {f32, int} {
	os.wait() or_return
	ret{*}urn 1
}
`,
		`package test

import "core:os"

run :: proc() -> union {bool, int} {
	os.wait() or_return
	return 1
}
`,
	)
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> union {u32, i32} {
	os.wait() or_return
	ret{*}urn 1
}
`,
	)
}

@(test)
result_union_constant_signed_float :: proc(t: ^testing.T) {
	expect_no_result_union(t, `package test

run :: proc() -> int {
	ret{*}urn -1.0
}
`)
	expect_result_union(
		t,
		`package test

run :: proc() -> int {
	ret{*}urn -1.5
}
`,
		`package test

run :: proc() -> f64 {
	return -1.5
}
`,
	)
}

@(test)
result_union_multiple_results_keep_names :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (count: int, failed: bool) {
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (count: int, failed: os.Error) {
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_multiple_results_split_shared_field :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (a, b, c: int) {
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (a, b: int, c: os.Error) {
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_multiple_results_matching_return :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(flag: bool) -> (int, bool) {
	os.re{*}ad("x") or_return
	if flag {
		return 1, true
	}
	return 2
}
`,
		`package test

import "core:os"

run :: proc(flag: bool) -> (result: int, err: union {os.Error, bool}) {
	os.read("x") or_return
	if flag {
		return 1, true
	}
	return 2
}
`,
	)
}

@(test)
result_union_multiple_results_forwarded_call :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (int, bool) {
	os.wait() or_return
	ret{*}urn os.pair()
}
`,
		`package test

import "core:os"

run :: proc() -> (result: int, err: union {bool, os.Error}) {
	os.wait() or_return
	return os.pair()
}
`,
	)
}

@(test)
result_union_multiple_results_constant :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (x: int, y: f32) {
	os.wa{*}it() or_return
	return 1, 2
}
`,
		`package test

import "core:os"

run :: proc() -> (x: int, y: union {bool, f32}) {
	os.wait() or_return
	return 1, 2
}
`,
	)
}

@(test)
result_union_multiple_results_nil_needs_nilable :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (int, int) {
	os.wa{*}it() or_return
	return 1, nil
}
`,
	)
}

@(test)
result_union_multiple_results_param_named_err :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc(err: int) -> (int, bool) {
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc(err: int) -> (result: int, err2: os.Error) {
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_multiple_results_types_match :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (int, os.Error) {
	os.re{*}ad("x") or_return
	return 1, nil
}
`,
	)
}

@(test)
result_union_multiple_results_on_return :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (int, os.Error) {
	e: os.Error
	os.wait() or_return
	re{*}turn 1, e
}
`,
		`package test

import "core:os"

run :: proc() -> (result: int, err: union {bool, os.Error}) {
	e: os.Error
	os.wait() or_return
	return 1, e
}
`,
	)
}

@(test)
result_union_multiple_results_cursor_elsewhere :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (int, os.Error) {
	x := 1{*}
	os.wait() or_return
	return x, nil
}
`,
	)
}

@(test)
result_union_multiple_results_forwarded_or_return :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (int, int) {
	ret{*}urn os.triple() or_return
}
`,
		`package test

import "core:os"

run :: proc() -> (result: int, err: union {bool, os.Error}) {
	return os.triple() or_return
}
`,
	)
}

@(test)
result_union_writes_named_last_result :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.General_Error) {
	err = .Exist
	if err != nil {
		return
	}
	data := os.re{*}ad("x") or_return
	return len(data), nil
}
`,
	)
}

@(test)
result_union_writes_named_single_result :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (err: int) {
	err = 5
	os.wa{*}it() or_return
	return
}
`,
	)
}

@(test)
result_union_compound_assigns_named_result :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (err: int) {
	err += 1
	os.wa{*}it() or_return
	return
}
`,
	)
}

@(test)
result_union_address_of_named_result :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

set :: proc(e: ^os.General_Error) {}

run :: proc() -> (n: int, err: os.General_Error) {
	set(&err)
	os.re{*}ad("x") or_return
	return
}
`,
	)
}

@(test)
result_union_reads_named_result :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (n: int, err: ^os.File) {
	if err != nil {
		return
	}
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.Error) {
	if err != nil {
		return
	}
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_deferred_nil_check :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (n: int, err: ^os.File) {
	defer if nil != err {}
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.Error) {
	defer if nil != err {}
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_compares_named_result :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.General_Error) {
	if err != .None {
		return
	}
	os.re{*}ad("x") or_return
	return
}
`,
	)
}

@(test)
result_union_passes_named_result :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

report :: proc(e: os.General_Error) {}

run :: proc() -> (n: int, err: os.General_Error) {
	defer report(err)
	os.re{*}ad("x") or_return
	return
}
`,
	)
}

@(test)
result_union_switches_on_named_result :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.General_Error) {
	defer switch err {
	case .Exist:
	}
	os.re{*}ad("x") or_return
	return
}
`,
	)
}

@(test)
result_union_writes_shadowing_local :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.General_Error) {
	{
		err := 1
		err = 2
	}
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.Error) {
	{
		err := 1
		err = 2
	}
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_returns_named_last_result :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

load :: proc() -> (shader: ^os.File, err: union {}) {
	path := os.jo{*}in("a") or_return
	data := os.read(path) or_return
	return shader, err
}
`,
		`package test
import "core:runtime"

import "core:os"

load :: proc() -> (shader: ^os.File, err: union {runtime.Allocator_Error, os.Error}) {
	path := os.join("a") or_return
	data := os.read(path) or_return
	return shader, err
}
`,
	)
}

@(test)
result_union_returns_named_result_first :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (a: os.General_Error, err: os.General_Error) {
	os.re{*}ad("x") or_return
	x: os.General_Error
	return err, x
}
`,
	)
}

@(test)
result_union_named_argument_value :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

set :: proc(err: os.General_Error) {}

run :: proc() -> (n: int, err: os.General_Error) {
	defer set(err = err)
	os.re{*}ad("x") or_return
	return
}
`,
	)
}

@(test)
result_union_selector_base :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

Bad :: struct {
	code: int,
}

run :: proc() -> (n: int, err: Bad) {
	defer if err.code != 0 {}
	os.re{*}ad("x") or_return
	return
}
`,
	)
}

@(test)
result_union_returns_call_on_named_result :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

wrap :: proc(e: os.General_Error) -> os.General_Error {
	return e
}

run :: proc() -> (err: os.General_Error) {
	os.wa{*}it() or_return
	return wrap(err)
}
`,
	)
}

@(test)
result_union_default_value_refused :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (ok: int = 1) {
	os.wa{*}it() or_return
	return ok
}
`,
	)
}

@(test)
result_union_keeps_result_list_comments :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (
	n: int, // count
	err: os.General_Error,
) {
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (
	n: int, // count
	err: os.Error,
) {
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_nested_proc_uses_result_name :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.General_Error) {
	helper :: proc(err: ^int) {
		err^ = 1
	}
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.Error) {
	helper :: proc(err: ^int) {
		err^ = 1
	}
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_field_named_like_result :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

Pair :: struct {
	err: int,
}

run :: proc(p: Pair) -> (n: int, err: os.General_Error) {
	defer if p.err != 0 {}
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

Pair :: struct {
	err: int,
}

run :: proc(p: Pair) -> (n: int, err: os.Error) {
	defer if p.err != 0 {}
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_implicit_selector_named_like_result :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

Kind :: enum {
	ok,
	err,
}

run :: proc(k: Kind) -> (n: int, err: os.General_Error) {
	defer if k == .err {}
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

Kind :: enum {
	ok,
	err,
}

run :: proc(k: Kind) -> (n: int, err: os.Error) {
	defer if k == .err {}
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_field_value_named_like_result :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

Pair :: struct {
	err: int,
}

run :: proc() -> (n: int, err: os.General_Error) {
	defer _ = Pair{err = 1}
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

Pair :: struct {
	err: int,
}

run :: proc() -> (n: int, err: os.Error) {
	defer _ = Pair{err = 1}
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_named_argument_named_like_result :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

set :: proc(err: os.General_Error) {}

run :: proc() -> (n: int, err: os.General_Error) {
	defer set(err = .Exist)
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

set :: proc(err: os.General_Error) {}

run :: proc() -> (n: int, err: os.Error) {
	defer set(err = .Exist)
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_nil_check_needs_nilable_type :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (n: int, err: ^os.File) {
	if err != nil {
		return
	}
	os.wa{*}it() or_return
	return
}
`,
	)
}

@(test)
result_union_nil_check_needs_nilable_single_type :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (err: ^os.File) {
	if err != nil {
		return
	}
	os.wa{*}it() or_return
	return
}
`,
	)
}

@(test)
result_union_map_literal_key :: proc(t: ^testing.T) {
	expect_no_result_union(
		t,
		`#+feature dynamic-literals
package test

import "core:os"

run :: proc() -> (n: int, err: os.General_Error) {
	defer _ = map[os.General_Error]int{err = 1}
	os.re{*}ad("x") or_return
	return
}
`,
	)
}

@(test)
result_union_names_blank_result :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (n: int, _: os.General_Error) {
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (n: int, err: os.Error) {
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_keeps_earlier_default_value :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (a: int = 1, err: os.General_Error) {
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (a: int = 1, err: os.Error) {
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_ignores_result_with_default_and_no_type :: proc(t: ^testing.T) {
	expect_no_result_union(t, `package test

run :: proc() -> (x := 1) {
	re{*}turn 2
}
`)
}

@(test)
result_union_comment_before_first_result :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (
	// first
	int,
	bool,
) {
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (
	// first
	result: int,
	err: os.Error,
) {
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_keeps_comments_and_lines_of_the_result_list :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (
	int, // count
	bool, // done
) {
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (
	result: int, // count
	err: os.Error, // done
) {
	os.read("x") or_return
	return
}
`,
	)
}

@(test)
result_union_keeps_comment_when_splitting_shared_field :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> (a, b, /* last */ c: int) {
	os.re{*}ad("x") or_return
	return
}
`,
		`package test

import "core:os"

run :: proc() -> (a, b: int, /* last */ c: os.Error) {
	os.read("x") or_return
	return
}
`,
	)
}

// The type text may name a package the file does not import: the action adds the import.
@(test)
result_union_adds_import_for_returned_error :: proc(t: ^testing.T) {
	expect_result_union(
		t,
		`package test

import "core:os"

run :: proc() -> union {} {
	os.wa{*}it() or_return
	_, err := os.join("a")
	return err
}
`,
		`package test
import "core:runtime"

import "core:os"

run :: proc() -> union {bool, runtime.Allocator_Error} {
	os.wait() or_return
	_, err := os.join("a")
	return err
}
`,
	)
}
