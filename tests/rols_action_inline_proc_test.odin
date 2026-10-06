package tests

import "core:testing"

import test "src:testing"

INLINE_PROC_ACTION :: "Inline procedure call"

expect_inline_proc :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_inline_proc = true},
	}
	test.expect_action_applied(t, &source, INLINE_PROC_ACTION, expected)
}

expect_no_inline_proc :: proc(t: ^testing.T, main: string, enabled := true) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_inline_proc = enabled},
	}
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

@(test)
action_inline_proc_expression :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	a := 1
	y := dou{*}ble(a + 1)
}
`, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	a := 1
	y := (a + 1) * 2
}
`)
}

@(test)
action_inline_proc_expression_in_binary :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	a := 1
	y := dou{*}ble(a) + 1
}
`, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	a := 1
	y := a * 2 + 1
}
`)
}

@(test)
action_inline_proc_refused_duplicated_call :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

square :: proc(x: int) -> int {
	return x * x
}

next :: proc() -> int {
	return 1
}

main :: proc() {
	y := squ{*}are(next())
}
`)
}

@(test)
action_inline_proc_statement :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

log :: proc(level: int, msg: string) {
	if level > 1 {
		print(msg)
	}
}

main :: proc() {
	n := 2
	lo{*}g(n + 1, "hi")
}
`, `package test

log :: proc(level: int, msg: string) {
	if level > 1 {
		print(msg)
	}
}

main :: proc() {
	n := 2
	{
		level: int = n + 1
		msg: string = "hi"
		if level > 1 {
			print(msg)
		}
	}
}
`)
}

@(test)
action_inline_proc_do_body :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

log :: proc(msg: string) do print(msg)

main :: proc() {
	lo{*}g("hi")
}
`, `package test

log :: proc(msg: string) do print(msg)

main :: proc() {
	{
		msg: string = "hi"
		print(msg)
	}
}
`)
}

@(test)
action_inline_proc_statement_same_name :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

bump :: proc(counter: ^int) {
	counter^ += 1
}

main :: proc() {
	counter := new(int)
	bu{*}mp(counter)
}
`, `package test

bump :: proc(counter: ^int) {
	counter^ += 1
}

main :: proc() {
	counter := new(int)
	{
		counter^ += 1
	}
}
`)
}

@(test)
action_inline_proc_refused_return :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

check :: proc(x: int) {
	if x > 1 {
		return
	}
	print(x)
}

main :: proc() {
	che{*}ck(1)
}
`)
}

@(test)
action_inline_proc_refused_group :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

double_int :: proc(x: int) -> int {
	return x * 2
}

double_f32 :: proc(x: f32) -> f32 {
	return x * 2
}

double :: proc {
	double_int,
	double_f32,
}

main :: proc() {
	y := dou{*}ble(1)
}
`)
}

@(test)
action_inline_proc_refused_variadic :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

first :: proc(xs: ..int) -> int {
	return xs[0]
}

main :: proc() {
	y := fir{*}st(1)
}
`)
}

@(test)
action_inline_proc_refused_other_package :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "my_package", source = `package my_package

double :: proc(x: int) -> int {
	return x * 2
}
`})
	source := test.Source {
		main = `package test

import "my_package"

main :: proc() {
	y := my_package.dou{*}ble(1)
}
`,
		packages = packages[:],
		config = {enable_code_action_inline_proc = true},
	}
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

@(test)
action_inline_proc_disabled :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	y := dou{*}ble(1)
}
`, enabled = false)
}

@(test)
action_inline_proc_refused_named_arguments :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

sub :: proc(a: int, b: int) -> int {
	return a - b
}

main :: proc() {
	y := su{*}b(b = 1, a = 2)
}
`)
}

@(test)
action_inline_proc_expression_with_omitted_literal_default :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

add :: proc(a: int, b: int = 2) -> int {
	return a + b
}

main :: proc() {
	y := ad{*}d(1)
}
`, `package test

add :: proc(a: int, b: int = 2) -> int {
	return a + b
}

main :: proc() {
	y := 1 + 2
}
`)
}

@(test)
action_inline_proc_refused_omitted_non_literal_default :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

base :: 2

add :: proc(a: int, b: int = base) -> int {
	return a + b
}

main :: proc() {
	y := ad{*}d(1)
}
`)
}

@(test)
action_inline_proc_refused_two_results :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

pair :: proc(x: int) -> (int, int) {
	return x, x
}

main :: proc() {
	a, b := pa{*}ir(1)
}
`)
}

@(test)
action_inline_proc_body_local_shadows_caller_local :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

use :: proc(x: int) {
}

scale :: proc(x: int) {
	tmp := x * 2
	use(tmp)
}

main :: proc() {
	tmp := 1
	sca{*}le(tmp)
}
`, `package test

use :: proc(x: int) {
}

scale :: proc(x: int) {
	tmp := x * 2
	use(tmp)
}

main :: proc() {
	tmp := 1
	{
		x: int = tmp
		tmp := x * 2
		use(tmp)
	}
}
`)
}

@(test)
action_inline_proc_force_inline_callee :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

double :: #force_inline proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	y := dou{*}ble(1)
}
`, `package test

double :: #force_inline proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	y := 1 * 2
}
`)
}

@(test)
action_inline_proc_recursive_one_level :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

countdown :: proc(n: int) -> int {
	return n <= 0 ? 0 : countdown(n - 1)
}

main :: proc() {
	y := coun{*}tdown(3)
}
`, `package test

countdown :: proc(n: int) -> int {
	return n <= 0 ? 0 : countdown(n - 1)
}

main :: proc() {
	y := 3 <= 0 ? 0 : countdown(3 - 1)
}
`)
}

@(test)
action_inline_proc_parenthesised_right_of_binary :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

inc :: proc(x: int) -> int {
	return x + 1
}

main :: proc() {
	a := 1
	y := 1 + in{*}c(a)
}
`, `package test

inc :: proc(x: int) -> int {
	return x + 1
}

main :: proc() {
	a := 1
	y := 1 + (a + 1)
}
`)
}

@(test)
action_inline_proc_twice_on_nested_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

double :: proc(x: int) -> int {
	return x * 2
}

inc :: proc(x: int) -> int {
	return x + 1
}

main :: proc() {
	a := 1
	y := dou{*}ble(inc(a))
}
`,
		config = {enable_code_action_inline_proc = true},
	}

	test.expect_action_chain(
		t,
		&source,
		{INLINE_PROC_ACTION, INLINE_PROC_ACTION},
		`package test

double :: proc(x: int) -> int {
	return x * 2
}

inc :: proc(x: int) -> int {
	return x + 1
}

main :: proc() {
	a := 1
	y := (a + 1) * 2
}
`,
		{"inc("},
	)
}

// Corpus: karl2d tests/coordinate_system/render_texture_flip_test.odin:75.
@(test)
action_inline_proc_offered_on_call_omitting_default_param :: proc(t: ^testing.T) {
	source := test.Source {
		main   = `package test

f :: proc(got: int, d := 0) {
	_ = got
}

g :: proc() {
	{*}f(1)
}
`,
		config = {enable_code_action_inline_proc = true},
	}
	test.expect_action(t, &source, {INLINE_PROC_ACTION})
}

@(test)
action_inline_proc_call_giving_every_arg_of_proc_with_default :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

f :: proc(got: int, d := 0) {
	_ = got + d
}

g :: proc() {
	{*}f(1, 2)
}
`, `package test

f :: proc(got: int, d := 0) {
	_ = got + d
}

g :: proc() {
	{
		got: int = 1
		d := 2
		_ = got + d
	}
}
`)
}

@(test)
action_inline_proc_used_literal_default_becomes_local :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

f :: proc(got: int, d := 0) {
	_ = got + d
}

g :: proc() {
	{*}f(1)
}
`, `package test

f :: proc(got: int, d := 0) {
	_ = got + d
}

g :: proc() {
	{
		got: int = 1
		d := 0
		_ = got + d
	}
}
`)
}

@(test)
action_inline_proc_refused_when_used_default_is_caller_location :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

f :: proc(got: int, loc := #caller_location) {
	_ = got
	_ = loc
}

g :: proc() {
	{*}f(1)
}
`)
}

@(test)
action_inline_proc_offered_when_unused_default_is_caller_location :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

f :: proc(got: int, loc := #caller_location) {
	_ = got
}

g :: proc() {
	{*}f(1)
}
`, `package test

f :: proc(got: int, loc := #caller_location) {
	_ = got
}

g :: proc() {
	{
		got: int = 1
		_ = got
	}
}
`)
}

@(test)
action_inline_proc_expression_literal_default_keeps_parameter_type :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

half :: proc(d: f32 = 2) -> f32 {
	return 1 / d
}

main :: proc() {
	y := ha{*}lf()
}
`, `package test

half :: proc(d: f32 = 2) -> f32 {
	return 1 / d
}

main :: proc() {
	y := 1 / f32(2)
}
`)
}

@(test)
action_inline_proc_expression_literal_argument_keeps_parameter_type :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

next :: proc(d: u8) -> u8 {
	return d + 1
}

main :: proc() {
	y := ne{*}xt(255)
}
`, `package test

next :: proc(d: u8) -> u8 {
	return d + 1
}

main :: proc() {
	y := u8(255) + 1
}
`)
}

inline_across_files :: proc(callee, caller: string) -> test.Source {
	files := make([]test.File, 1, context.temp_allocator)
	files[0] = {"a.odin", callee}
	return test.Source{main = caller, files = files, config = {enable_code_action_inline_proc = true}}
}

@(test)
action_inline_proc_callee_in_other_file :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

draw :: proc(x, y: int) {
	_ = x + y
}
`, `package test

main :: proc() {
	dr{*}aw(1, 2)
}
`)
	test.expect_action_applied(t, &source, INLINE_PROC_ACTION, `package test

main :: proc() {
	{
		x: int = 1
		y: int = 2
		_ = x + y
	}
}
`)
}

@(test)
action_inline_proc_refused_file_private_callee_of_body :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

@(private = "file")
norm :: proc(v: int) -> int {
	return v
}

draw :: proc(x, y: int) {
	_ = norm(x)
	_ = y
}
`, `package test

main :: proc() {
	dr{*}aw(1, 2)
}
`)
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

@(test)
action_inline_proc_refused_declaration_of_private_file :: proc(t: ^testing.T) {
	source := inline_across_files(`#+private file
package test

LIMIT :: 3

draw :: proc(x: int) {
	_ = x + LIMIT
}
`, `package test

main :: proc() {
	dr{*}aw(1)
}
`)
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

// The caller's file gets the import that the copied text needs.
@(test)
action_inline_proc_adds_import_the_caller_lacks :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

import "core:time"

wait :: proc(d: time.Duration) {
	_ = d
}
`, `package test

main :: proc() {
	wa{*}it(5)
}
`)
	test.expect_action_applied(t, &source, INLINE_PROC_ACTION, `package test
import "core:time"

main :: proc() {
	{
		d: time.Duration = 5
		_ = d
	}
}
`)
}

@(test)
action_inline_proc_refused_import_under_another_alias :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

import t "core:time"

wait :: proc(d: t.Duration) {
	_ = d
}
`, `package test

import "core:time"

main :: proc() {
	wa{*}it(5)
}
`)
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

@(test)
action_inline_proc_import_both_files_share :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

import "core:time"

wait :: proc(d: time.Duration) {
	_ = d
}
`, `package test

import "core:time"

main :: proc() {
	wa{*}it(5)
}
`)
	test.expect_action_applied(t, &source, INLINE_PROC_ACTION, `package test

import "core:time"

main :: proc() {
	{
		d: time.Duration = 5
		_ = d
	}
}
`)
}

// Corpus: manual check, repro3. The body redeclares a parameter, which clashes with the local that binds the argument.
@(test)
action_inline_proc_refused_body_shadows_parameter :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

Vec :: [2]f32

emit :: proc(v: Vec, uv: Vec) {
	v := v
	v.x += 1
	_ = uv
}

g :: proc(vs: [2]Vec) {
	em{*}it(vs[0], {0, 0})
}
`)
}

// Corpus: the solved symbol of a polymorphic call loses `generic`, and inlining leaves `T` undeclared.
@(test)
action_inline_proc_refused_polymorphic :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

bytes_of :: proc(ptr: ^$T) -> int {
	return size_of(T)
}

main :: proc() {
	x := 1
	n := byt{*}es_of(&x)
}
`)
	expect_no_inline_proc(t, `package test

report :: proc($T: typeid) {
	_ = size_of(T)
}

main :: proc() {
	rep{*}ort(int)
}
`)
	expect_no_inline_proc(t, `package test

twice :: proc(x: int) -> int where size_of(int) == 8 {
	return x * 2
}

main :: proc() {
	n := twi{*}ce(1)
}
`)
}

@(test)
action_inline_proc_refused_polymorphic_in_other_file :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

bytes_of :: proc(ptr: ^$T) -> int {
	return size_of(T)
}
`, `package test

main :: proc() {
	x := 1
	n := byt{*}es_of(&x)
}
`)
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

// The caller's local LIMIT would capture the body's use of the package constant.
@(test)
action_inline_proc_refused_caller_local_shadows_body_name :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

LIMIT :: 3

draw :: proc(x: int) {
	_ = x + LIMIT
}

main :: proc() {
	LIMIT := 10
	dr{*}aw(1)
	_ = LIMIT
}
`)
}

@(test)
action_inline_proc_refused_caller_local_shadows_body_name_across_files :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

LIMIT :: 3

draw :: proc(x: int) {
	_ = x + LIMIT
}
`, `package test

main :: proc() {
	for LIMIT in 0 ..< 2 {
		dr{*}aw(LIMIT)
	}
}
`)
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

// An import of the caller's file under a name the body takes from the package changes what it means.
@(test)
action_inline_proc_refused_caller_import_shadows_body_name :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

time :: 3

draw :: proc(x: int) {
	_ = x + time
}
`, `package test

import "core:time"

main :: proc() {
	dr{*}aw(1)
}
`)
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

// A package constant that both the body and the caller use is the same declaration after inlining.
@(test)
action_inline_proc_body_and_caller_share_a_global :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

LIMIT :: 3

draw :: proc(x: int) {
	_ = x + LIMIT
}

main :: proc() {
	n := LIMIT
	dr{*}aw(n)
}
`, `package test

LIMIT :: 3

draw :: proc(x: int) {
	_ = x + LIMIT
}

main :: proc() {
	n := LIMIT
	{
		x: int = n
		_ = x + LIMIT
	}
}
`)
}

// The loop's LIMIT ends with the loop, so the later use reads the package constant, which main's local would capture.
@(test)
action_inline_proc_refused_body_name_bound_outside_its_loop :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

LIMIT :: 3

draw :: proc(x: int) {
	for LIMIT in 0 ..< x {
		_ = LIMIT
	}
	_ = x + LIMIT
}

main :: proc() {
	LIMIT := 10
	dr{*}aw(1)
	_ = LIMIT
}
`)
}

@(test)
action_inline_proc_refused_type_switch_variable_shadows_body_name :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

LIMIT :: 3

draw :: proc(x: int) {
	_ = x + LIMIT
}

main :: proc() {
	v: union {
		int,
		f32,
	}
	switch LIMIT in v {
	case int:
		dr{*}aw(LIMIT)
	}
}
`)
}

@(test)
action_inline_proc_refused_range_reference_shadows_body_name :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

LIMIT :: 3

draw :: proc(x: int) {
	_ = x + LIMIT
}

main :: proc() {
	xs := [2]int{1, 2}
	for &LIMIT in xs {
		dr{*}aw(LIMIT)
	}
}
`)
}

// A map key is a value, so main's LIMIT would capture it.
@(test)
action_inline_proc_refused_map_key_shadowed :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

LIMIT :: 3

draw :: proc(x: int) {
	m := map[int]int{LIMIT = x}
	_ = m
}

main :: proc() {
	LIMIT := 10
	dr{*}aw(LIMIT)
}
`)
}

// A file-private LIMIT of the caller's file shadows the package constant the body reads.
@(test)
action_inline_proc_refused_caller_file_private_shadows_body_name :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

LIMIT :: 3

draw :: proc(x: int) {
	_ = x + LIMIT
}
`, `package test

@(private = "file")
LIMIT :: 10

main :: proc() {
	dr{*}aw(1)
}
`)
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

// The caller's x and i are other bindings than the parameter x and the loop's i, so the copy keeps its meaning.
@(test)
action_inline_proc_caller_and_callee_bind_the_same_name :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

draw :: proc(x: int) {
	for i in 0 ..< x {
		_ = i
	}
}

main :: proc() {
	x := 1
	for i in 0 ..< 2 {
		dr{*}aw(x)
		_ = i
	}
}
`, `package test

draw :: proc(x: int) {
	for i in 0 ..< x {
		_ = i
	}
}

main :: proc() {
	x := 1
	for i in 0 ..< 2 {
		{
			for i in 0 ..< x {
				_ = i
			}
		}
		_ = i
	}
}
`)
}

// A named slice type makes LIMIT an index, which main's local would capture.
@(test)
action_inline_proc_refused_slice_index_shadowed :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

LIMIT :: 1
Ints :: []int

draw :: proc(x: int) {
	s := Ints{LIMIT = x}
	_ = s
}

main :: proc() {
	LIMIT := 10
	dr{*}aw(LIMIT)
}
`)
}

// An aliased import is added under its alias, after the caller's imports of the same collection.
@(test)
action_inline_proc_adds_aliased_import :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

import tm "core:time"

wait :: proc(d: tm.Duration) {
	_ = d
}
`, `package test

import "core:fmt"

main :: proc() {
	wa{*}it(5)
	fmt.println()
}
`)
	test.expect_action_applied(t, &source, INLINE_PROC_ACTION, `package test

import "core:fmt"
import tm "core:time"

main :: proc() {
	{
		d: tm.Duration = 5
		_ = d
	}
	fmt.println()
}
`)
}

// A local time at the call would capture the added import's name.
@(test)
action_inline_proc_refused_import_name_taken_by_caller_local :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

import "core:time"

wait :: proc(d: time.Duration) {
	_ = d
}
`, `package test

main :: proc() {
	time := 1
	wa{*}it(5)
	_ = time
}
`)
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

// The caller imports the same package under another name.
@(test)
action_inline_proc_refused_import_of_same_path_under_other_name :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

import "core:time"

wait :: proc(d: time.Duration) {
	_ = d
}
`, `package test

import tm "core:time"

main :: proc() {
	wa{*}it(5)
	_ = tm.Duration(1)
}
`)
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

// The parameter fmt shadows the import of the callee's file, so the copy does not use the import.
@(test)
action_inline_proc_parameter_named_like_callee_import :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

import "core:fmt"

g :: proc(fmt: int) -> int {
	return fmt + 1
}
`, `package test

main :: proc() {
	x := {*}g(2)
	_ = x
}
`)
	test.expect_action_applied(t, &source, INLINE_PROC_ACTION, `package test

main :: proc() {
	x := 2 + 1
	_ = x
}
`)
}

// The untyped literal is a map, so LIMIT is a key that main's local would capture.
@(test)
action_inline_proc_refused_untyped_map_key_shadowed :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

LIMIT :: 3

draw :: proc(x: int) {
	m: map[int]int = {LIMIT = x}
	_ = m
}

main :: proc() {
	LIMIT := 10
	dr{*}aw(LIMIT)
}
`)
}

// The untyped literal is a map, so the key k is the parameter.
@(test)
action_inline_proc_untyped_map_key_is_parameter :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

keyed :: proc(k: int) -> map[int]int {
	return {k = 1}
}

main :: proc() {
	m: map[int]int = ke{*}yed(5)
	_ = m
}
`, `package test

keyed :: proc(k: int) -> map[int]int {
	return {k = 1}
}

main :: proc() {
	m: map[int]int = map[int]int{5 = 1}
	_ = m
}
`)
}

// The untyped literal is a struct, so x on the left is a field name and stays. The copy names the
// result type, since `p := {x = 1}` does not compile.
@(test)
action_inline_proc_untyped_struct_field_named_like_parameter :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

Point :: struct {
	x: int,
}

make_point :: proc(x: int) -> Point {
	return {x = x}
}

main :: proc() {
	p := make_po{*}int(1)
	_ = p
}
`, `package test

Point :: struct {
	x: int,
}

make_point :: proc(x: int) -> Point {
	return {x = x}
}

main :: proc() {
	p := Point{x = 1}
	_ = p
}
`)
}

// The literal's type does not resolve, so k may be a field or a key.
@(test)
action_inline_proc_refused_unresolved_literal_key_named_like_parameter :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

keyed :: proc(k: int) -> Missing {
	return {k = 1}
}

main :: proc() {
	m := ke{*}yed(5)
	_ = m
}
`)
}

// Corpus: karl2d karl2d.odin:5723:20. An implicit selector argument needs no parentheses.
@(test)
action_inline_proc_implicit_selector_argument :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

Button :: enum {
	Left,
	Right,
}

arr: [Button]bool

get :: proc(b: Button) -> bool {
	return arr[b]
}

main :: proc() {
	_ = g{*}et(.Left)
}
`, `package test

Button :: enum {
	Left,
	Right,
}

arr: [Button]bool

get :: proc(b: Button) -> bool {
	return arr[b]
}

main :: proc() {
	_ = arr[.Left]
}
`)
}

// The untyped literal is resolved in the callee's file, which the client has not opened.
@(test)
action_inline_proc_untyped_struct_literal_from_other_file :: proc(t: ^testing.T) {
	source := inline_across_files(`package test

Point :: struct {
	x: int,
}

make_point :: proc(x: int) -> Point {
	return {x = x}
}
`, `package test

main :: proc() {
	p := make_po{*}int(1)
	_ = p
}
`)
	test.expect_action_applied(t, &source, INLINE_PROC_ACTION, `package test

main :: proc() {
	p := Point{x = 1}
	_ = p
}
`)
}
