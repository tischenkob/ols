package tests

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

import test "src:testing"

@(private = "file")
Packages :: []test.Package

@(private = "file")
MEM := Packages{{pkg = "mem", source = "package mem\n\nKilobyte :: 1024\nMegabyte :: 1024 * Kilobyte\ncounter: int\n"}}

@(private = "file")
reach_source :: proc(main: string, packages: Packages = {}) -> test.Source {
	source := test.Source {
		main = main,
		packages = packages,
		config = {
			enable_code_action_extract_variable = true,
			enable_code_action_extract_constant = true,
			enable_code_action_extract_procedure = true,
			enable_code_action_add_explicit_type = true,
			enable_code_action_introduce_param = true,
			enable_code_action_remove_param = true,
		},
	}
	if len(packages) > 0 {
		source.collections = make(map[string]string, context.temp_allocator)
		source.collections["core"] = "test"
	}
	return source
}

// The same source with the code point after the `{*}` marker selected, the range a client sends for a cursor.
@(private = "file")
one_character_range :: proc(main: string) -> string {
	at := strings.index(main, "{*}")
	rest := main[at + 3:]
	_, width := utf8.decode_rune_in_string(rest)
	return strings.concatenate({main[:at], "{[", rest[:width], "]}", rest[width:]}, context.temp_allocator)
}

@(private = "file")
expect_applied :: proc(t: ^testing.T, main, title, expected: string, packages: Packages = {}) {
	source := reach_source(main, packages)
	test.expect_action_applied(t, &source, title, expected)
}

// Asserts the action at the empty cursor and at the one-character range.
@(private = "file")
expect_reach :: proc(t: ^testing.T, main, title, expected: string, packages: Packages = {}) {
	expect_applied(t, main, title, expected, packages)
	expect_applied(t, one_character_range(main), title, expected, packages)
}

@(private = "file")
expect_refused :: proc(t: ^testing.T, main: string, titles: ..string) {
	for title in titles {
		source := reach_source(main)
		test.expect_action_missing(t, &source, title)
	}
}

@(private = "file")
expect_refused_with :: proc(t: ^testing.T, main: string, packages: Packages, titles: ..string) {
	for title in titles {
		source := reach_source(main, packages)
		test.expect_action_missing(t, &source, title)
	}
}

// One test per row of the measured table: each position that gained an action.
@(test)
rols_cursor_reach :: proc(t: ^testing.T) {
	SELECTOR_AFTER :: `package test

Range :: struct {
	start, end: int,
}
Ctx :: struct {
	range: Range,
}

trim :: proc(a, b: int) -> (int, int) {
	return a, b
}

main :: proc(ctx: ^Ctx) {
	start := ctx.range.start
	x, y := trim(start, ctx.range.end)
	_, _ = x, y
}
`
	SELECTOR_MAIN :: `package test

Range :: struct {
	start, end: int,
}
Ctx :: struct {
	range: Range,
}

trim :: proc(a, b: int) -> (int, int) {
	return a, b
}

main :: proc(ctx: ^Ctx) {
	x, y := trim(%s, ctx.range.end)
	_, _ = x, y
}
`
	selector_main := proc(selection: string) -> string {
		text, _ := strings.replace_all(SELECTOR_MAIN, "%s", selection, context.temp_allocator)
		return text
	}

	// A cursor and a one-character range on `ctx.range.start`.
	expect_reach(t, selector_main("ctx.range.st{*}art"), "Extract variable", SELECTOR_AFTER)
	// Inexact selections, inside the expression and past it with the separator.
	expect_applied(t, selector_main("c{[tx.range.start]}"), "Extract variable", SELECTOR_AFTER)
	{
		swept, _ := strings.replace_all(SELECTOR_MAIN, "%s, ", "{[ctx.range.start, ]}", context.temp_allocator)
		expect_applied(t, swept, "Extract variable", SELECTOR_AFTER)
	}

	// Extract procedure at a cursor, at a one-character range and at a mid-statement selection.
	PROCEDURE_AFTER :: `package test

main :: proc() {
	a := 1
	extracted(a)
}

extracted :: proc(a: int) {
	b := a + 1
	_ = b
}
`
	expect_reach(
		t,
		`package test

main :: proc() {
	a := 1
	b := a + 1
	_ = {*}b
}
`,
		"Extract procedure",
		`package test

main :: proc() {
	a := 1
	b := a + 1
	extracted(b)
}

extracted :: proc(b: int) {
	_ = b
}
`,
	)
	expect_applied(
		t,
		`package test

main :: proc() {
	a := 1
	b := a{[ + 1
	_ =]} b
}
`,
		"Extract procedure",
		PROCEDURE_AFTER,
	)
	expect_applied(
		t,
		`package test

main :: proc() {
	a := 1
	{[b := a + 1
	_ = b]}
}
`,
		"Extract procedure",
		PROCEDURE_AFTER,
	)

	// A literal under the cursor, as a whole initializer.
	expect_reach(
		t,
		`package test

main :: proc() {
	base := "val{*}ue"
	_ = base
}
`,
		"Extract variable",
		`package test

main :: proc() {
	value := "value"
	base := value
	_ = base
}
`,
	)

	// The iterable of a range loop.
	expect_reach(
		t,
		`package test

items :: proc(a: int) -> []int {
	return nil
}

main :: proc() {
	for x in it{*}ems(1) {
		_ = x
	}
}
`,
		"Extract variable",
		`package test

items :: proc(a: int) -> []int {
	return nil
}

main :: proc() {
	items2 := items(1)
	for x in items2 {
		_ = x
	}
}
`,
	)

	// The subject of a type switch, under `#partial`.
	expect_reach(
		t,
		`package test

U :: union {
	int,
}

main :: proc(chain: []U) {
	#partial switch p in cha{*}in[len(chain) - 1] {
	case int:
		_ = p
	}
}
`,
		"Extract variable",
		`package test

U :: union {
	int,
}

main :: proc(chain: []U) {
	value := chain[len(chain) - 1]
	#partial switch p in value {
	case int:
		_ = p
	}
}
`,
	)

	// An expression in an `if` init.
	expect_reach(
		t,
		`package test

Node :: struct {
	u: union {
		int,
	},
}

main :: proc(node: Node) {
	if _, ok := no{*}de.u.(int); ok {
	}
}
`,
		"Extract variable",
		`package test

Node :: struct {
	u: union {
		int,
	},
}

main :: proc(node: Node) {
	u := node.u
	if _, ok := u.(int); ok {
	}
}
`,
	)

	// A selector naming a package constant.
	expect_reach(
		t,
		`package test

import "mem"

reserve :: proc(n: int) {
}

main :: proc() {
	reserve(mem.Mega{*}byte * 100)
}
`,
		"Extract constant (mem.Megabyte)",
		`package test

import "mem"

reserve :: proc(n: int) {
}

CONSTANT :: mem.Megabyte

main :: proc() {
	reserve(CONSTANT * 100)
}
`,
		MEM,
	)

	// Column 1 of an indented line reaches the first token.
	expect_reach(
		t,
		`package test

main :: proc() {
{*}	a := 1
	_ = a
}
`,
		"Extract procedure",
		`package test

main :: proc() {
	a := extracted()
	_ = a
}

extracted :: proc() -> int {
	a := 1
	return a
}
`,
	)

	// The value side of a declaration.
	expect_reach(
		t,
		`package test

Stmt :: struct {
	offset: int,
}

main :: proc(stmt: Stmt) {
	line_start := stmt.off{*}set
	_ = line_start
}
`,
		"Add explicit type",
		`package test

Stmt :: struct {
	offset: int,
}

main :: proc(stmt: Stmt) {
	line_start: int = stmt.offset
	_ = line_start
}
`,
	)
}

@(test)
rols_cursor_reach_surrogate_pair_is_one_character :: proc(t: ^testing.T) {
	// Without the collapse, the selection would snap to one width only.
	main := "package test\n\nbaz :: proc(s: string) -> int {\n\treturn 0\n}\n\nbar :: proc(n: int) {\n}\n\nmain :: proc() {\n\tbar(baz(\"{[\U0001F600]}\") + 1)\n}\n"
	source := reach_source(main)
	test.expect_action(t, &source, {"Extract variable (baz(\"\U0001F600\") + 1)"})
}

@(test)
rols_cursor_reach_blank_line_stays :: proc(t: ^testing.T) {
	expect_refused(t, `package test

main :: proc() {
	a := 1
{*}	
	_ = a
}
`, "Extract procedure")
}

@(test)
rols_cursor_reach_refused :: proc(t: ^testing.T) {
	// A `for` condition and post statement.
	expect_refused(
		t,
		`package test

main :: proc() {
	s := []int{1}
	for i := 0; i < l{*}en(s); i += 1 {
	}
}
`,
		"Extract variable",
		"Extract variable (len(s))",
		"Extract variable (i < len(s))",
	)
	expect_refused(
		t,
		`package test

main :: proc(a: ^[1]int) {
	for i := 0; i < 1; i += a[{*}0] {
	}
}
`,
		"Extract variable",
		"Extract variable (0)",
		"Extract variable (a[0])",
	)
	// `defer`.
	expect_refused(
		t,
		`package test

foo :: proc(n: int) {
}

main :: proc(a: []int) {
	defer foo(le{*}n(a))
}
`,
		"Extract variable",
		"Extract variable (len(a))",
	)
	// The right side of `&&`, and of `||` and `or_else`.
	// Only the whole condition is left, and the plain title shows that it is the one width offered.
	expect_applied(
		t,
		`package test

main :: proc(a: []int) {
	if true && le{*}n(a) > 0 {
	}
}
`,
		"Extract variable",
		`package test

main :: proc(a: []int) {
	value := true && len(a) > 0
	if value {
	}
}
`,
	)
	expect_refused(
		t,
		`package test

main :: proc(a: []int) {
	x := true && le{*}n(a) > 0
	_ = x
}
`,
		"Extract variable",
		"Extract variable (len(a))",
		"Extract variable (len(a) > 0)",
	)
	expect_refused(
		t,
		`package test

main :: proc(a: []int) {
	x := false || le{*}n(a) > 0
	_ = x
}
`,
		"Extract variable",
		"Extract variable (len(a))",
		"Extract variable (len(a) > 0)",
	)
	// A ternary branch.
	expect_refused(
		t,
		`package test

main :: proc(a: []int, c: bool) {
	x := c ? le{*}n(a) : 0
	_ = x
}
`,
		"Extract variable",
		"Extract variable (len(a))",
	)
	// A range as an iterable.
	expect_refused(t, `package test

main :: proc(n: int) {
	for i in 0..{*}<n {
		_ = i
	}
}
`, "Extract variable")
	expect_refused(
		t,
		`package test

main :: proc(n: int) {
	for i in {[0..<n]} {
		_ = i
	}
}
`,
		"Extract variable",
		"Extract constant",
	)
	// The loop would iterate a copy.
	expect_refused(
		t,
		`package test

A :: struct {
	items: [4]int,
}

main :: proc(a: ^A) {
	for &x in a.ite{*}ms {
		x = 1
	}
}
`,
		"Extract variable",
	)
	// So would a bound type switch.
	expect_refused(
		t,
		`package test

A :: struct {
	u: union {
		int,
	},
}

main :: proc(a: ^A) {
	switch &v in a.{*}u {
	case int:
		v = 1
	}
}
`,
		"Extract variable",
	)
	// A local inside size_of cannot move to package scope.
	expect_refused(t, `package test

main :: proc() {
	x := 1
	y := size_of{*}(x)
	_ = y
}
`, "Extract constant")
	// Neither can a poly parameter, or an implicit selector.
	expect_refused(t, `package test

main :: proc($T: typeid) {
	y := size_of{*}(T)
	_ = y
}
`, "Extract constant")
	expect_refused(
		t,
		`package test

E :: enum {
	A,
}

main :: proc() {
	y := E.A == .{*}A
	_ = y
}
`,
		"Extract constant",
		"Extract constant (.A)",
	)
	// `::` declarations, at package level.
	expect_refused(t, `package test

N :: 1 +{*} 2
`, "Extract constant")
}

// Each of these would hoist out of what the statement keeps meaning.
@(test)
rols_cursor_reach_keeps_behavior :: proc(t: ^testing.T) {
	// The loop calls an iterator every round.
	expect_refused(
		t,
		`package test

next :: proc(a: ^int) -> (int, bool) {
	return 0, false
}

main :: proc(s: ^[]^int) {
	for x in next(s[{*}0]) {
		_ = x
	}
}
`,
		"Extract variable",
		"Extract variable (s[0])",
		"Extract variable (next(s[0]))",
		"Extract variable (0)",
	)
	// A literal fed to another type takes its default type in a variable.
	expect_refused(t, `package test

main :: proc(f: f32) {
	x := f * {*}2
	_ = x
}
`, "Extract variable")
	expect_refused(
		t,
		`package test

foo :: proc(c: cstring) {
}

main :: proc() {
	foo("a{*}b")
}
`,
		"Extract variable",
	)
	// A parameter that must be constant.
	expect_refused(t, `package test

foo :: proc($N: int) {
}

main :: proc() {
	foo({*}3)
}
`, "Extract variable")
	// A type needs a constant.
	expect_refused(
		t,
		`package test

N :: 2

main :: proc() {
	x: [N + {*}1]int
	_ = x
}
`,
		"Extract variable",
		"Extract variable (1)",
		"Extract variable (N + 1)",
	)
	// An init whose earlier call would run after the extraction.
	expect_refused(
		t,
		`package test

g :: proc() -> int {
	return 0
}

A :: struct {
	b: int,
}

main :: proc(a: A) {
	if x := g() + a.{*}b; x > 0 {
	}
}
`,
		"Extract variable",
	)
	// A name the init declares.
	expect_refused(
		t,
		`package test

A :: struct {
	b: int,
}

main :: proc() {
	if x, a := 1, A{}; x + a.{*}b > 0 {
	}
}
`,
		"Extract variable",
	)
	// A label or a directive stays in front of the statement, so the statement cannot become a call.
	expect_refused(
		t,
		`package test

main :: proc(s: []int) {
	outer: for {*}x in s {
		_ = x
		break outer
	}
}
`,
		"Extract procedure",
	)
	expect_refused(t, `package test

main :: proc(n: int) {
	#partial sw{*}itch n {
	}
}
`, "Extract procedure")
}

// Extract procedure gathers locals at the statement start, and gives up on the write to `p`. Extract
// constant runs later and must still see the `b` that shadows the constant.
@(test)
rols_cursor_reach_extract_procedure_restores_locals :: proc(t: ^testing.T) {
	expect_refused(
		t,
		`package test

b :: 1

main :: proc(p: int) {
	if b := 2; b + {*}1 > 0 {
		p = 1
	}
}
`,
		"Extract constant (b + 1)",
	)
}

@(test)
rols_cursor_reach_extract_variable_positions :: proc(t: ^testing.T) {
	// A switch tag and a labeled loop.
	expect_reach(
		t,
		`package test

A :: struct {
	b: int,
}

main :: proc(a: A) {
	switch a.{*}b {
	}
}
`,
		"Extract variable",
		`package test

A :: struct {
	b: int,
}

main :: proc(a: A) {
	b := a.b
	switch b {
	}
}
`,
	)
	expect_reach(
		t,
		`package test

main :: proc(s: [][]int) {
	outer: for x in s[{*}0] {
		_ = x
		break outer
	}
}
`,
		"Extract variable",
		`package test

main :: proc(s: [][]int) {
	value := s[0]
	outer: for x in value {
		_ = x
		break outer
	}
}
`,
	)
	// The init of a C-style loop, and an `if` init.
	expect_reach(
		t,
		`package test

main :: proc(s: []int) {
	for i := l{*}en(s) - 1; i >= 0; i -= 1 {
	}
}
`,
		"Extract variable",
		`package test

main :: proc(s: []int) {
	len2 := len(s)
	for i := len2 - 1; i >= 0; i -= 1 {
	}
}
`,
	)
	// A literal fed to a matching parameter, a matching operand, an `any` and a return.
	expect_reach(
		t,
		`package test

foo :: proc(s: string) {
}

main :: proc() {
	foo("a{*}b")
}
`,
		"Extract variable",
		`package test

foo :: proc(s: string) {
}

main :: proc() {
	value := "ab"
	foo(value)
}
`,
	)
	expect_reach(
		t,
		`package test

main :: proc() -> int {
	return 4{*}2
}
`,
		"Extract variable",
		`package test

main :: proc() -> int {
	value := 42
	return value
}
`,
	)
}

@(test)
rols_cursor_reach_extract_constant_forms :: proc(t: ^testing.T) {
	// An inexact selection snaps to the smallest constant around it.
	expect_applied(
		t,
		`package test

foo :: proc(n: int) {
}

main :: proc() {
	foo({[1 +]} 2)
}
`,
		"Extract constant",
		`package test

foo :: proc(n: int) {
}

N :: 1 + 2

main :: proc() {
	foo(N)
}
`,
	)
	// An enum member, a conversion and size_of of a package name.
	expect_reach(
		t,
		`package test

E :: enum {
	A,
}

foo :: proc(e: E) {
}

main :: proc() {
	foo(E.{*}A)
}
`,
		"Extract constant",
		`package test

E :: enum {
	A,
}

foo :: proc(e: E) {
}

E2 :: E.A

main :: proc() {
	foo(E2)
}
`,
	)
	expect_applied(
		t,
		`package test

foo :: proc(n: u8) {
}

main :: proc() {
	foo({[u8(3)]})
}
`,
		"Extract constant",
		`package test

foo :: proc(n: u8) {
}

N :: u8(3)

main :: proc() {
	foo(N)
}
`,
	)
	expect_reach(
		t,
		`package test

T :: struct {
	a: int,
}

main :: proc() {
	x := size_of{*}(T) + 1
	_ = x
}
`,
		"Extract constant (size_of(T))",
		`package test

T :: struct {
	a: int,
}

CONSTANT :: size_of(T)

main :: proc() {
	x := CONSTANT + 1
	_ = x
}
`,
	)
	// A package-level `:=` initializer.
	expect_reach(
		t,
		`package test

// Doc.
x := {*}3 + 4
`,
		"Extract constant (3)",
		`package test

CONSTANT :: 3

// Doc.
x := CONSTANT + 4
`,
	)
	// A mutable package variable is no constant.
	expect_refused_with(
		t,
		`package test

import "mem"

main :: proc() {
	x := mem.coun{*}ter
	_ = x
}
`,
		MEM,
		"Extract constant",
	)
}

@(test)
rols_cursor_reach_introduce_param :: proc(t: ^testing.T) {
	// A widened constant that holds a selector or a call stays out.
	expect_refused_with(
		t,
		`package test

import "mem"

foo :: proc() -> int {
	return mem.Mega{*}byte + 1
}

bar :: proc() {
	foo()
}
`,
		MEM,
		"Introduce parameter",
		"Introduce parameter (mem.Megabyte)",
		"Introduce parameter (mem.Megabyte + 1)",
	)
	expect_refused(t, `package test

foo :: proc() -> int {
	return size_of{*}(int)
}
`, "Introduce parameter")
	// A literal keeps its offer.
	expect_reach(
		t,
		`package test

foo :: proc() -> int {
	return {*}3
}

bar :: proc() {
	foo()
}
`,
		"Introduce parameter",
		`package test

foo :: proc(value: int) -> int {
	return value
}

bar :: proc() {
	foo(3)
}
`,
	)
}

@(test)
rols_cursor_reach_add_explicit_type_not_in_body :: proc(t: ^testing.T) {
	expect_refused(
		t,
		`package test

run :: proc(f: proc()) -> int {
	return 0
}

main :: proc() {
	x := run(proc() {
		fo{*}o()
	})
	_ = x
}
`,
		"Add explicit type",
	)
}

@(test)
rols_cursor_reach_remove_param :: proc(t: ^testing.T) {
	AFTER :: `package test

foo :: proc(b: int) {
	_ = b
}

main :: proc() {
	foo(2)
}
`
	expect_reach(
		t,
		`package test

foo :: proc(a: in{*}t, b: int) {
	_ = b
}

main :: proc() {
	foo(1, 2)
}
`,
		"Remove parameter a",
		AFTER,
	)
	expect_refused(
		t,
		`package test

foo :: proc(a, b: in{*}t) {
}

main :: proc() {
	foo(1, 2)
}
`,
		"Remove parameter a",
		"Remove parameter b",
	)
}

// A parameter or a result written `name := value` has no type expression to compare a literal against.
@(test)
rols_cursor_reach_literal_inferred_type_refused :: proc(t: ^testing.T) {
	expect_refused(t, `package test

foo :: proc(a := 1) {}

main :: proc() {
	foo({*}2)
}
`, "Extract variable")
	expect_refused(
		t,
		`package test

foo :: proc(a: int, b := 5) {}

main :: proc() {
	foo(1, {*}2)
}
`,
		"Extract variable",
	)
	expect_refused(t, `package test

f :: proc() -> (n := 0) {
	return {*}5
}
`, "Extract variable")
}
