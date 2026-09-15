package tests

import "core:testing"

import "src:common"
import test "src:testing"

Lint_Case :: struct {
	name:   string,
	source: string,
	expect: []test.LintExpect,
}

// Each case is linted on its own; a failure is followed by the name of the case that produced it.
expect_lint_cases :: proc(
	t: ^testing.T,
	cases: []Lint_Case,
	config: common.Config,
	packages: []test.Package = nil,
	collections: map[string]string = nil,
) {
	for c in cases {
		source := test.Source {
			main        = c.source,
			packages    = packages,
			collections = collections,
			config      = config,
		}
		before := t.error_count
		test.expect_lint_diagnostics(t, &source, c.expect)
		if t.error_count > before {
			testing.expectf(t, false, "in case %q", c.name)
		}
	}
}

@(test)
lint_self_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: int,
}

f :: proc(y: int) -> int {
	return y
}

main :: proc() {
	x := 1
	y := 2
	p: P
	x = x
	p.x = p.x
	x = y
	x, y = y, x
	x = f(x)
	x += x
}
`,
		config = {enable_lint_self_assignment = true},
	}

	test.expect_lint_diagnostics(t, &source, {{14, "self-assignment"}, {15, "self-assignment"}})
}

@(test)
lint_identical_branches :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(c: bool) -> int {
	x := 0
	if c {
		x = 1
	} else {
		x = 1
	}
	if c {
		x = 1
	} else {
		x = 2
	}
	if c {
		x = 1
	} else if !c {
		x = 1
	}
	x = c ? 3 : 3
	x = c ? 3 : 4
	return x
}
`,
		config = {enable_lint_identical_branches = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "identical-branches"}, {19, "identical-branches"}})
}

@(test)
lint_unreachable_code :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(c: bool) -> int {
	if c {
		return 1
	}
	for {
		if c {
			break
		}
		continue
		_ = c
	}
	switch c {
	case true:
		panic("no")
		return 2
		return 3
	}
	return 0
	return 1
}
`,
		config = {enable_lint_unreachable_code = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{20, "unreachable-code"}, {11, "unreachable-code"}, {16, "unreachable-code"}},
	)
}

@(test)
lint_unreachable_code_range :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> int {
	return 0
	a := 1
	b := 2
	return a + b
}
`,
		config = {enable_lint_unreachable_code = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "unreachable-code"}})
}

@(test)
lint_float_equality :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: f32,
	n: int,
}

f :: proc(a, b: f32, i, j: int, p: P) -> bool {
	r := a == b
	r = i == j
	r = i != 1
	r = i == 1.5
	r = p.x != p.x
	r = p.n == p.n
	r = a < b
	return r
}
`,
		config = {enable_lint_float_equality = true},
	}

	test.expect_lint_diagnostics(t, &source, {{8, "float-equality"}, {11, "float-equality"}, {12, "float-equality"}})
}

@(test)
lint_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: f32) -> bool {
	x := 1
	x = x
	if a == 1.0 {
		return true
	} else {
		return true
	}
	return false
	return false
}
`,
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
lint_ignored_result :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "testing"

Allocator_Error :: enum {
	None,
	Out_Of_Memory,
}

Parse_Error :: union {
	Allocator_Error,
}

append_elem :: proc(array: ^$T/[dynamic]$E, arg: E) -> (n: int, err: Allocator_Error) #optional_allocator_error {
	return 0, .None
}

append :: proc {
	append_elem,
}

delete_slice :: proc(array: $T/[]$E, allocator := context.allocator) -> Allocator_Error {
	return .None
}

delete :: proc {
	delete_slice,
}

ok_proc :: proc() -> bool {
	return true
}

set_env :: proc(key, value: string) -> bool {
	return true
}

alloc_proc :: proc() -> (int, Allocator_Error) {
	return 0, .None
}

union_proc :: proc() -> Parse_Error {
	return nil
}

int_proc :: proc() -> int {
	return 0
}

main :: proc() {
	xs: [dynamic]int
	append(&xs, 1)
	s: []int
	delete(s)
	ok_proc()
	_ = ok_proc()
	set_env("a", "b")
	(alloc_proc())
	union_proc()
	int_proc()
	defer ok_proc()
	if ok_proc() {
	}
	tt: ^testing.T
	testing.expect(tt, true)
}
`,
		packages = {
			{
				pkg = "testing",
				source = `package testing
T :: struct {}
expect :: proc(t: ^T, ok: bool) -> bool {
	return ok
}
`,
			},
		},
		config = {enable_lint_ignored_result = true},
	}

	test.expect_lint_diagnostics(t, &source, {{54, "ignored-result"}, {56, "ignored-result"}, {58, "ignored-result"}})
}

@(test)
lint_unused_parameter :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: int,
}

used :: proc(a: int, b: int) -> int {
	return a
}

closure :: proc(a: int, b: int) -> int {
	f := proc(x: int) -> int {
		return x
	}
	return f(a)
}

underscore :: proc(_: int, _unused: int) {
	x := 1
}

using_param :: proc(using p: P) {
	x := 1
}

poly :: proc($T: typeid, v: T, n: int) {
	x := 1
}

stub :: proc(a: int) {
}

todo :: proc(a: int) {
	unreachable()
}

@(export)
exported :: proc(a: int) {
	x := 1
}

callback :: proc "c" (a: int) {
	x := 1
}

anon := proc(a: int, b: int) -> int {
	return b
}

field_name :: proc(x: int, y: int) -> P {
	return P{x = y}
}
`,
		config = {enable_lint_unused_parameter = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{6, "unused-parameter"},
			{10, "unused-parameter"},
			{25, "unused-parameter"},
			{45, "unused-parameter"},
			{49, "unused-parameter"},
		},
	)
}

@(test)
lint_results_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

ok_proc :: proc(a: int) -> bool {
	return true
}

main :: proc() {
	ok_proc(1)
}
`,
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
lint_naming :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

draw_sprite :: proc(sprite_id: int, N: int) {
	local_ok := 1
	localBad := 2
	Local_Const :: 3
	LOCAL_CONST :: 4
}

draw_Sprite :: proc(spriteId: int) {
}

Sprite_Batch :: struct {
	sprite_count: int,
	spriteCount:  int,
}

sprite_batch :: struct {}

Vec2 :: [2]f32

Mouse_Button :: enum {
	Left_Button,
	right_button,
	RIGHT = 3,
}

Slot :: enum {
	_1,
	_2,
	_Bad,
}

Flags :: bit_field u8 {
	is_on: bool | 1,
	isOff: bool | 1,
}

MAX_ENTITIES :: 100
maxEntities :: 100
ORIGIN :: Vec2{0, 0}
Origin :: Vec2{0, 0}
Meters :: distinct f32
meters :: distinct f32
Callback :: #type proc(x: int)
Handle :: Meters
Vector :: struct($T: typeid) {}
Vec_F32 :: Vector(f32)
w :: f32(48)
Scale :: Meters(2)
Small :: struct($N: int, $T: typeid) {}
Item_List :: Small(16, int)
when ODIN_OS == .Windows {
	maxPath :: 260
}

my_var := 1
myVar := 2

main :: proc() {
}
`,
		config = {enable_lint_naming = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{4, "naming"},
			{9, "naming"},
			{9, "naming"},
			{14, "naming"},
			{17, "naming"},
			{23, "naming"},
			{30, "naming"},
			{35, "naming"},
			{39, "naming"},
			{41, "naming"},
			{43, "naming"},
			{48, "naming"},
			{49, "naming"},
			{53, "naming"},
			{57, "naming"},
		},
	)
}

@(test)
lint_naming_exemptions :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:fmt"

@(export)
BadName :: proc() {}

@(link_name = "c_thing")
Other_Bad :: proc() {}

foreign import lib "system:c"

foreign lib {
	SDL_CreateWindow :: proc(windowTitle: cstring) -> rawptr ---
	gExternal: i32
}

println :: fmt.println
SCALE :: #config(SCALE, 2)
scale :: #config(SCALE, 2)

generic :: proc($T: typeid, N: int, using Base_Params: Sprite, _: int) {}

Sprite :: struct {}
SDL_Window :: struct {}
HTTP_OK :: 200
Vec2 :: [2]f32
Ada_Const :: Vec2{}
`,
		config = {enable_lint_naming = true},
	}

	test.expect_lint_diagnostics(t, &source, {{27, "naming"}})
}

@(test)
lint_naming_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

draw_Sprite :: proc() {
}
`,
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
lint_self_assignment_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	a: int,
	b: int,
}

f :: proc(xs: []int, i, j: int, p: ^int, u, v: S) {
	xs := xs
	u := u
	x := 1
	xs[i] = xs[i]
	xs [i] = xs[i]
	x = (x)
	xs[i] = xs[j]
	u.b = v.a
	p^ = p^
	{
		x := x
		_ = x
	}
}
`,
		config = {enable_lint_self_assignment = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{11, "self-assignment"}, {12, "self-assignment"}, {13, "self-assignment"}, {16, "self-assignment"}},
	)
}

@(test)
lint_identical_branches_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc() {}

f :: proc(c, d: bool) -> string {
	if c {
		g()
	} else if d {
		g()
		g()
	} else {
		g()
		g()
	}
	if c {
		// first
		g()
	} else {
		g()
	}
	if c {
		return "a"
	} else {
		return "A"
	}
	if c do g() else do g()
	return ""
}
`,
		config = {enable_lint_identical_branches = true},
	}

	// A comment in one branch and a string differing only in case both keep the branches apart.
	test.expect_lint_diagnostics(t, &source, {{7, "identical-branches"}, {25, "identical-branches"}})
}

@(test)
lint_identical_branches_empty :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(c: bool) {
	if c {
	} else {
	}
}
`,
		config = {enable_lint_identical_branches = true, enable_lint_no_op = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "identical-branches"}, {3, "empty-body"}, {4, "empty-body"}})
}

@(test)
lint_unreachable_code_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc() {}

after_unreachable :: proc() {
	unreachable()
	g()
}

after_for :: proc() {
	for {
		g()
	}
	g()
}

return_in_if :: proc(c: bool) {
	if c {
		return
	}
	g()
}

defer_after_return :: proc() {
	return
	defer g()
}

comment_only :: proc() {
	return
	// nothing here
}

after_fallthrough :: proc(x: int) {
	switch x {
	case 1:
		fallthrough
		g()
	case 2:
		g()
	}
}
`,
		config = {enable_lint_unreachable_code = true},
	}

	// A statement after `for {}` is not reported.
	test.expect_lint_diagnostics(
		t,
		&source,
		{{6, "unreachable-code"}, {25, "unreachable-code"}, {37, "unreachable-code"}},
	)
}

@(test)
lint_float_equality_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

PI :: 3.14

f :: proc(a: f32, b: f64, x, y: int, eps: f32) -> bool {
	r := a == 1.0
	r = b != b
	r = abs(a - eps) == 0
	r = a == 0
	r = x == 1
	r = f32(x) == f32(y)
	r = PI == 3.14
	switch a {
	case 1.0:
		r = true
	}
	return r
}
`,
		config = {enable_lint_float_equality = true},
	}

	// A call result, a conversion and a switch case go unreported.
	test.expect_lint_diagnostics(
		t,
		&source,
		{{5, "float-equality"}, {6, "float-equality"}, {8, "float-equality"}, {11, "float-equality"}},
	)
}

@(test)
lint_ignored_result_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Err :: enum {
	None,
}

opt_ok :: proc(m: map[int]int, k: int) -> (int, bool) #optional_ok {
	return m[k], false
}

maybe_proc :: proc() -> Maybe(int) {
	return nil
}

err_proc :: proc() -> Err {
	return .None
}

main :: proc() {
	m: map[int]int
	opt_ok(m, 1)
	maybe_proc()
	p := err_proc
	p()
}
`,
		config = {enable_lint_ignored_result = true},
	}

	test.expect_lint_diagnostics(t, &source, {{21, "ignored-result"}, {23, "ignored-result"}})
}

@(test)
lint_unused_parameter_scopes :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc(v: int) {}

in_when :: proc(a: int) {
	when ODIN_DEBUG {
		x := a
		_ = x
	}
}

in_defer :: proc(a: int) {
	defer g(a)
	x := 1
	_ = x
}

named_results :: proc(a: int) -> (out: int) {
	out = a
	return
}

group_a :: proc(a: int) {
	x := 1
	_ = x
}

group_b :: proc(a: string) {
	x := 1
	_ = x
}

grouped :: proc {
	group_a,
	group_b,
}
`,
		config = {enable_lint_unused_parameter = true},
	}

	// A use inside `when` or `defer` counts, a named result is not a parameter, and every member
	// of a proc group is checked on its own.
	test.expect_lint_diagnostics(t, &source, {{22, "unused-parameter"}, {27, "unused-parameter"}})
}
