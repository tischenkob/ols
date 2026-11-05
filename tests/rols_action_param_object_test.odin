package tests

import "core:testing"

import test "src:testing"

@(private = "file")
PARAM_OBJECT :: "Introduce parameter object"

@(private = "file")
object_source :: proc(main: string, files: []test.File = {}, enabled := true) -> test.Source {
	return {main = main, files = files, config = {enable_code_action_param_object = enabled}}
}

@(private = "file")
expect_no_param_object :: proc(t: ^testing.T, main: string, files: []test.File = {}, enabled := true) {
	source := object_source(main, files, enabled)
	test.expect_action_missing(t, &source, PARAM_OBJECT)
}

@(test)
param_object_across_files :: proc(t: ^testing.T) {
	source := object_source(
		`package test

draw_rect :: proc({[x: f32, y]}: f32, color: int) -> f32 {
	return x + y + f32(color)
}

main :: proc() {
	_ = draw_rect(1, 2, 3)
}
`,
		{{"b.odin", `package test

other :: proc(a: f32) {
	_ = draw_rect(a, a * 2, 0)
}
`}},
	)
	test.expect_action_applied_files(
		t,
		&source,
		PARAM_OBJECT,
		{
			{
				"main.odin",
				`package test

draw_rect :: proc(params: Draw_Rect_Params, color: int) -> f32 {
	return params.x + params.y + f32(color)
}

Draw_Rect_Params :: struct {
	x: f32,
	y: f32,
}

main :: proc() {
	_ = draw_rect(Draw_Rect_Params{x = 1, y = 2}, 3)
}
`,
			},
			{
				"b.odin",
				`package test

other :: proc(a: f32) {
	_ = draw_rect(Draw_Rect_Params{x = a, y = a * 2}, 0)
}
`,
			},
		},
	)
}

// A local that shadows a parameter keeps its own name.
@(test)
param_object_keeps_a_shadowing_local :: proc(t: ^testing.T) {
	main := `package test

sum :: proc({[a: int, b]}: int) -> int {
	{
		a := 3
		_ = a
	}
	return a + b
}
`
	local := object_source(main)
	test.expect_action_applied(
		t,
		&local,
		PARAM_OBJECT,
		`package test

sum :: proc(params: Sum_Params) -> int {
	{
		a := 3
		_ = a
	}
	return params.a + params.b
}

Sum_Params :: struct {
	a: int,
	b: int,
}
`,
	)
}

@(test)
param_object_refuses_unsupported_shapes :: proc(t: ^testing.T) {
	shapes := []string {
		// One parameter is not an object.
		"package test\n\nf :: proc({[a]}: int, b: int) {\n\t_ = a + b\n}\n",
		// A default value, `using` and a parametric parameter.
		"package test\n\nf :: proc({[a: int, b := 2]}) {\n\t_ = a + b\n}\n",
		"package test\n\nP :: struct {\n\tx: int,\n}\n\nf :: proc({[using p: P, b: int]}) {\n\t_ = x + b\n}\n",
		"package test\n\nf :: proc({[a: $T, b: int]}) {\n\t_ = b\n}\n",
		// The type name, or `params`, is taken.
		"package test\n\nF_Params :: struct {}\n\nf :: proc({[a: int, b: int]}) {\n\t_ = a + b\n}\n",
		"package test\n\nparams := 1\n\nf :: proc({[a: int, b: int]}) {\n\t_ = a + b + params\n}\n",
		"package test\n\nf :: proc({[a: int, b: int]}, params: int) {\n\t_ = a + b + params\n}\n",
		// Part of a field that declares two names.
		"package test\n\nf :: proc({[a: int, b]}, c: int) {\n\t_ = a + b + c\n}\n",
		// A comment between the parameters would be lost.
		"package test\n\nf :: proc({[a: int, /* why */ b: int]}) {\n\t_ = a + b\n}\n",
		// A value use, and a call nested in an argument of another call.
		"package test\n\nf :: proc({[a: int, b: int]}) -> int {\n\treturn a + b\n}\n\nkeep := f\n",
		"package test\n\nf :: proc({[a: int, b: int]}) -> int {\n\treturn a + b\n}\n\nmain :: proc() {\n\t_ = f(f(1, 2), 3)\n}\n",
	}
	for shape in shapes {
		expect_no_param_object(t, shape)
	}
}

@(test)
param_object_refuses_when_disabled :: proc(t: ^testing.T) {
	expect_no_param_object(t, "package test\n\nf :: proc({[a: int, b: int]}) {\n\t_ = a + b\n}\n", enabled = false)
}
