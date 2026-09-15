package tests

import "core:testing"

import test "src:testing"

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
			{29, "naming"},
			{33, "naming"},
			{35, "naming"},
			{37, "naming"},
			{44, "naming"},
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
lint_naming_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"procedure names",
			`package test

myProc :: proc() {}
My_Proc :: proc() {}
MYPROC :: proc() {}
snake_case :: proc() {}
`,
			{{2, "naming"}, {3, "naming"}, {4, "naming"}},
		},
		{
			// Ada_Case only requires each `_` segment to start with an upper case letter or a digit.
			"type names",
			`package test

my_type :: struct {}
MyType :: struct {}
Vec3 :: [3]f32
Vector3 :: struct {}
HTTPClient :: struct {}
`,
			{{2, "naming"}},
		},
		{
			"enum members follow the type rule",
			`package test

E :: enum {
	myValue,
	MY_VALUE,
	Good_Value,
}
`,
			{{3, "naming"}},
		},
		{
			"constant names",
			`package test

pi :: 3.14
Max :: 1
MAX_2D :: 2
`,
			{{2, "naming"}, {3, "naming"}},
		},
		{
			"type alias follows the type rule",
			`package test

Foo :: int
`,
			{},
		},
		{
			"proc group follows the procedure rule",
			`package test

a :: proc(x: int) {}
b :: proc(x: f32) {}

foo :: proc {
	a,
	b,
}

badGroup :: proc {
	a,
	b,
}
`,
			{{10, "naming"}},
		},
		{
			"variable names",
			`package test

myVar := 1
my_var := 2
`,
			{{2, "naming"}},
		},
		{
			"blanks, single letters and non-ASCII pass",
			`package test

f :: proc(_: int, _unused: int, T: int, i: int) {}

größe := 1
`,
			{},
		},
		{
			"polymorphic parameters are not names",
			`package test

generic :: proc($T: typeid, $N: int) {}
`,
			{},
		},
		{
			"private is not an external name",
			`package test

@(private)
internal_Proc :: proc() {}
`,
			{{3, "naming"}},
		},
		{
			"struct fields and parameters",
			`package test

S :: struct {
	myField: int,
}

f :: proc(myParam: int) {}
`,
			{{3, "naming"}, {6, "naming"}},
		},
		{
			"labels are not checked",
			`package test

f :: proc(n: int) {
	myLoop: for i in 0 ..< n {
		break myLoop
	}
}
`,
			{},
		},
		{
			"declarations inside when",
			`package test

when ODIN_DEBUG {
	badName :: proc() {}
}
`,
			{{3, "naming"}},
		},
		{
			"a selector use is not a declaration",
			`package test

import "other"

f :: proc() {
	other.badName()
}
`,
			{},
		},
	}

	expect_lint_cases(
		t,
		cases,
		{enable_lint_naming = true},
		{{pkg = "other", source = `package other
badName :: proc() {}
`}},
	)
}
