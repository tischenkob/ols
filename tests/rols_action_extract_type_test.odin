package tests

import "core:testing"

import test "src:testing"

@(private = "file")
EXTRACT_TYPE :: "Extract type"
@(private = "file")
INLINE_ALIAS :: "Inline type alias"

@(private = "file")
type_source :: proc(main: string, files: []test.File = {}, enabled := true) -> test.Source {
	return {main = main, files = files, config = {enable_code_action_extract_type = enabled}}
}

@(private = "file")
expect_type_action :: proc(t: ^testing.T, title, main, expected: string) {
	source := type_source(main)
	test.expect_action_applied(t, &source, title, expected)
}

@(private = "file")
expect_no_type_action :: proc(t: ^testing.T, title, main: string, files: []test.File = {}, enabled := true) {
	source := type_source(main, files, enabled)
	test.expect_action_missing(t, &source, title)
}

@(test)
extract_type_struct_field :: proc(t: ^testing.T) {
	expect_type_action(
		t,
		EXTRACT_TYPE,
		`package test

Config :: struct {
	opts: str{*}uct {
		x: int,
		y: bool,
	},
}
`,
		`package test

Config :: struct {
	opts: Opts,
}

Opts :: struct {
	x: int,
	y: bool,
}
`,
	)
}

// The name takes the next free number, and the type goes after the procedure that holds it.
@(test)
extract_type_parameter_and_local :: proc(t: ^testing.T) {
	expect_type_action(
		t,
		EXTRACT_TYPE,
		`package test

Cb :: int

run :: proc(cb: pr{*}oc(a: int) -> int) -> int {
	return cb(1)
}
`,
		`package test

Cb :: int

run :: proc(cb: Cb2) -> int {
	return cb(1)
}

Cb2 :: proc(a: int) -> int
`,
	)
	expect_type_action(
		t,
		EXTRACT_TYPE,
		`package test

main :: proc() {
	mode: en{*}um u8 {
		Off,
		On,
	}
	mode = .On
	_ = mode
}
`,
		`package test

main :: proc() {
	mode: Mode
	mode = .On
	_ = mode
}

Mode :: enum u8 {
	Off,
	On,
}
`,
	)
}

@(test)
extract_type_long_array :: proc(t: ^testing.T) {
	expect_type_action(
		t,
		EXTRACT_TYPE,
		`package test

Mesh :: struct {
	grid: [4]{*}[4]f32,
}
`,
		`package test

Mesh :: struct {
	grid: Grid,
}

Grid :: [4][4]f32
`,
	)
	expect_no_type_action(t, EXTRACT_TYPE, `package test

Mesh :: struct {
	xs: []i{*}nt,
}
`)
}

// A poly parameter or a local type means nothing at file scope, and a second spelling of the same struct would no
// longer match the named one.
@(test)
extract_type_refusals :: proc(t: ^testing.T) {
	expect_no_type_action(
		t,
		EXTRACT_TYPE,
		`package test

wrap :: proc(v: $T) {
	box: str{*}uct {
		value: T,
	}
	box.value = v
}
`,
	)
	expect_no_type_action(
		t,
		EXTRACT_TYPE,
		`package test

main :: proc() {
	Local :: struct {
		x: int,
	}
	box: str{*}uct {
		value: Local,
	}
	_ = box
}
`,
	)
	expect_no_type_action(
		t,
		EXTRACT_TYPE,
		`package test

Config :: struct {
	opts: str{*}uct {
		x: int,
	},
}
`,
		{{"b.odin", "package test\n\ntake :: proc(opts: struct {\n\tx: int,\n}) {}\n"}},
	)
	expect_no_type_action(
		t,
		EXTRACT_TYPE,
		`package test

Config :: struct {
	opts: str{*}uct {
		x: int,
	},
}
`,
		enabled = false,
	)
}

// A conversion of a pointer alias needs parentheses, or it would dereference the converted value.
@(test)
inline_type_alias_same_file :: proc(t: ^testing.T) {
	expect_type_action(
		t,
		INLINE_ALIAS,
		`package test

Point :: struct {
	x, y: f32,
}

// The point we use.
P{*}t :: Point

Ptr :: ^int

origin :: proc() -> Pt {
	return Pt{}
}
`,
		`package test

Point :: struct {
	x, y: f32,
}

Ptr :: ^int

origin :: proc() -> Point {
	return Point{}
}
`,
	)
	expect_type_action(
		t,
		INLINE_ALIAS,
		`package test

Pt{*}r :: ^int

main :: proc() {
	p := Ptr(nil)
	_ = p
}
`,
		`package test

main :: proc() {
	p := (^int)(nil)
	_ = p
}
`,
	)
}

@(test)
inline_type_alias_across_files :: proc(t: ^testing.T) {
	source := type_source(
		`package test

In{*}ts :: []int

first :: proc(xs: Ints) -> int {
	return xs[0]
}
`,
		{{"b.odin", "package test\n\nlast :: proc(xs: Ints) -> int {\n\treturn xs[len(xs) - 1]\n}\n"}},
	)
	test.expect_action_applied_files(
		t,
		&source,
		INLINE_ALIAS,
		{
			{"main.odin", "package test\n\nfirst :: proc(xs: []int) -> int {\n\treturn xs[0]\n}\n"},
			{"b.odin", "package test\n\nlast :: proc(xs: []int) -> int {\n\treturn xs[len(xs) - 1]\n}\n"},
		},
	)
}

// distinct and a struct declare a type, a parametric alias needs its arguments, a procedure is no type, and a local
// in another file would take the name that the alias reads.
@(test)
inline_type_alias_refusals :: proc(t: ^testing.T) {
	shapes := []string {
		"package test\n\nMy{*}_Int :: distinct int\n",
		"package test\n\nFo{*}o :: struct {\n\tx: int,\n}\n",
		"package test\n\nOp{*}t :: Maybe\n",
		"package test\n\nOp{*}t :: Maybe(int)\n",
		"package test\n\nf :: proc() {}\n\ng{*} :: f\n",
		"package test\n\nN{*} :: 5\n",
	}
	for shape in shapes {
		expect_no_type_action(t, INLINE_ALIAS, shape)
	}
	expect_no_type_action(
		t,
		INLINE_ALIAS,
		"package test\n\nPoint :: struct {\n\tx: int,\n}\n\nP{*}t :: Point\n",
		{{"b.odin", "package test\n\nf :: proc(p: Pt) {\n\tPoint := 1\n\t_ = Point\n}\n"}},
	)
	expect_no_type_action(t, INLINE_ALIAS, "package test\n\nIn{*}ts :: []int\n", enabled = false)
}
