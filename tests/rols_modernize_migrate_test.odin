package tests

import "core:testing"

import test "src:testing"

@(private = "file")
STRCONV := []test.Package {
	{
		pkg = "strconv",
		source = `package strconv
write_int :: proc(buf: []byte, i: i64, base: int) -> string { return "" }
write_float :: proc(buf: []byte, f: f64, fmt: byte, prec, bit_size: int) -> string { return "" }
@(deprecated="Use strconv.write_int() instead")
itoa :: proc(buf: []byte, i: int) -> string { return write_int(buf, i64(i), 10) }
@(deprecated="Use strconv.write_float() instead")
ftoa :: proc(buf: []byte, f: f64, fmt: byte, prec, bit_size: int) -> string { return write_float(buf, f, fmt, prec, bit_size) }
`,
	},
}

@(private = "file")
migrate :: proc(t: ^testing.T, main, expected: string, rules: []string = {"migration"}) {
	src := test.Source {
		main     = main,
		packages = STRCONV,
	}
	test.expect_modernized(t, &src, rules, expected)
}

@(test)
migrate_base_imports :: proc(t: ^testing.T) {
	migrate(
		t,
		`package test

import "core:runtime"
import "core:intrinsics"
import rt "core:builtin"
`,
		`package test

import "base:runtime"
import "base:intrinsics"
import rt "base:builtin"
`,
	)
}

@(test)
migrate_base_imports_keeps_duplicate :: proc(t: ^testing.T) {
	src := `package test

import "base:runtime"
import "core:runtime"
`
	migrate(t, src, src)
}

@(test)
migrate_os2_import :: proc(t: ^testing.T) {
	migrate(t, `package test

import "core:os/os2"
`, `package test

import os2 "core:os"
`)
	migrate(t, `package test

import fs "core:os/os2"
`, `package test

import fs "core:os"
`)
}

@(test)
migrate_os2_import_with_os :: proc(t: ^testing.T) {
	src := `package test

import "core:os"
import "core:os/os2"
`
	migrate(t, src, src)
}

@(test)
migrate_struct_directives :: proc(t: ^testing.T) {
	migrate(
		t,
		`package test

A :: struct #field_align(4) {
	a: u8,
}
B :: struct #field_align 4 #max_field_align 8 {
	a: u8,
}
C :: struct #align 2 * 4 {
	a: u8,
}
U :: union #align 8 {
	int,
}
D :: struct #align(8) #min_field_align(4) {
	a: u8,
}
`,
		`package test

A :: struct #min_field_align(4) {
	a: u8,
}
B :: struct #min_field_align(4) #max_field_align(8) {
	a: u8,
}
C :: struct #align(2 * 4) {
	a: u8,
}
U :: union #align(8) {
	int,
}
D :: struct #align(8) #min_field_align(4) {
	a: u8,
}
`,
	)
}

// A directive cannot be split from its expression by a line comment, so the scans stay on the
// expression's line; a comment ending in the old name is never renamed.
@(test)
migrate_field_align_skips_comment :: proc(t: ^testing.T) {
	migrate(
		t,
		`package test

// was #field_align
A :: struct #min_field_align(4) {
	a: u8,
}
B :: struct #align /* #field_align */ 8 {
	a: u8,
}
`,
		`package test

// was #field_align
A :: struct #min_field_align(4) {
	a: u8,
}
B :: struct #align /* #field_align */(8) {
	a: u8,
}
`,
	)
}

@(test)
migrate_blank_loops_and_switches :: proc(t: ^testing.T) {
	migrate(
		t,
		`package test

U :: union {
	int,
	f32,
}

main :: proc() {
	xs := []int{1, 2}
	for in xs {
	}
	for x in xs {
		_ = x
	}
	u: U
	switch in u {
	case int, f32:
	}
	switch v in u {
	case int, f32:
		_ = v
	}
	#partial #partial switch _ in u {
	case int:
	}
	#partial  #partial switch u {
	case int:
	}
}
`,
		`package test

U :: union {
	int,
	f32,
}

main :: proc() {
	xs := []int{1, 2}
	for _ in xs {
	}
	for x in xs {
		_ = x
	}
	u: U
	switch _ in u {
	case int, f32:
	}
	switch v in u {
	case int, f32:
		_ = v
	}
	#partial switch _ in u {
	case int:
	}
	#partial switch u {
	case int:
	}
}
`,
	)
}

@(test)
migrate_partial_dup_skips_comment :: proc(t: ^testing.T) {
	src := `package test

E :: enum {
	A,
	B,
}

g :: proc() -> E {
	return .A
}

main :: proc() {
	// was #partial
	#partial switch g() {
	case .A:
	}
}
`
	migrate(t, src, src)
}

@(test)
migrate_optimization_mode :: proc(t: ^testing.T) {
	migrate(
		t,
		`package test

@(optimization_mode = "speed")
a :: proc() {}
@(optimization_mode = "size")
b :: proc() {}
@(optimization_mode = "minimal")
c :: proc() {}
@(optimization_mode = "none")
d :: proc() {}
`,
		`package test

@(optimization_mode = "favor_size")
a :: proc() {}
@(optimization_mode = "favor_size")
b :: proc() {}
@(optimization_mode = "none")
c :: proc() {}
@(optimization_mode = "none")
d :: proc() {}
`,
	)
}

@(test)
migrate_proc_do_body :: proc(t: ^testing.T) {
	migrate(
		t,
		`package test

twice :: proc(x: int) -> int do return x * 2

main :: proc() {
	f := proc() do twice(1)
	f()
}
`,
		`package test

twice :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	f := proc() {
		twice(1)
	}
	f()
}
`,
	)
}

@(test)
migrate_strconv :: proc(t: ^testing.T) {
	migrate(
		t,
		`package test

import "strconv"

main :: proc() {
	buf: [32]u8
	_ = strconv.itoa(buf[:], 1 + 2)
	_ = strconv.ftoa(buf[:], 1.5, 'f', 2, 64)
}
`,
		`package test

import "strconv"

main :: proc() {
	buf: [32]u8
	_ = strconv.write_int(buf[:], i64(1 + 2), 10)
	_ = strconv.write_float(buf[:], 1.5, 'f', 2, 64)
}
`,
	)
}

@(test)
migrate_strconv_alias :: proc(t: ^testing.T) {
	migrate(
		t,
		`package test

import sc "strconv"

main :: proc() {
	buf: [32]u8
	_ = sc.itoa(buf[:], 7)
}
`,
		`package test

import sc "strconv"

main :: proc() {
	buf: [32]u8
	_ = sc.write_int(buf[:], i64(7), 10)
}
`,
	)
}

@(test)
migrate_strconv_look_alike :: proc(t: ^testing.T) {
	src := `package test

Conv :: struct {
	itoa: proc(buf: []byte, i: int) -> string,
}

main :: proc() {
	strconv: Conv
	buf: [32]u8
	_ = strconv.itoa(buf[:], 7)
}
`
	migrate(t, src, src)
}

@(test)
migrate_feature_tags :: proc(t: ^testing.T) {
	migrate(
		t,
		`#+build linux
// Package docs.
package test

S :: struct {
	a: int,
}

f :: proc(using s: S) -> int {
	return a
}

main :: proc() {
	m := map[string]int {
		"a" = 1,
	}
	_ = m
}
`,
		`#+build linux
#+feature using-stmt
#+feature dynamic-literals
// Package docs.
package test

S :: struct {
	a: int,
}

f :: proc(using s: S) -> int {
	return a
}

main :: proc() {
	m := map[string]int {
		"a" = 1,
	}
	_ = m
}
`,
	)
	migrate(
		t,
		`// Package docs.
package test

S :: struct {
	a: int,
}

main :: proc() {
	s: S
	using s
	_ = a
	d := [dynamic]int{}
	_ = d
}
`,
		`#+feature using-stmt
// Package docs.
package test

S :: struct {
	a: int,
}

main :: proc() {
	s: S
	using s
	_ = a
	d := [dynamic]int{}
	_ = d
}
`,
	)
}

@(test)
migrate_feature_tags_block_comment :: proc(t: ^testing.T) {
	migrate(
		t,
		`/*
License.
*/ package test

main :: proc() {
	_ = [dynamic]int{1}
}
`,
		`#+feature dynamic-literals
/*
License.
*/ package test

main :: proc() {
	_ = [dynamic]int{1}
}
`,
	)
}

@(test)
migrate_feature_tags_present :: proc(t: ^testing.T) {
	src := `#+feature dynamic-literals using-stmt
package test

S :: struct {
	using inner: struct {
		a: int,
	},
}

f :: proc(using s: S) {}

main :: proc() {
	_ = [dynamic]int{1}
}
`
	migrate(t, src, src)
}

@(test)
migrate_file_tags_review :: proc(t: ^testing.T) {
	src := `//+build windows
//+private
// Not a tag: //+build linux
package test
`
	migrate(t, src, src)
	migrate(t, src, `#+build windows
#+private
// Not a tag: //+build linux
package test
`, {"file-tags"})
}
