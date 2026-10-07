package tests

import "core:testing"

import test "src:testing"

@(test)
lint_argument_count :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "other"

f :: proc(a: int, b: int) {}

g :: proc(a: int, b := 2) {}

pair :: proc(a, b: int) {}

variadic :: proc(a: int, rest: ..int) {}

poly :: proc(x: $T) {}

main :: proc() {
	f(1)
	f(1, 2)
	f(1, 2, 3)
	g()
	g(1)
	pair(1)
	variadic(1)
	poly(1)
	f(b = 2, a = 1)
	unknown(1)
	other.two(1)
	other.two(1, 2)
}
`,
		packages = {{pkg = "other", source = `package other
two :: proc(a: int, b: int) {}
`}},
		config = {enable_lint_call_arity = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{15, "argument-count"},
			{17, "argument-count"},
			{18, "argument-count"},
			{20, "argument-count"},
			{25, "argument-count"},
		},
	)
}

@(test)
lint_call_arity_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"a procedure value is not checked",
			`package test

f :: proc(a: int, b: int) {}

main :: proc() {
	p := f
	p(1)
}
`,
			{},
		},
		{
			"a spread argument hides the count",
			`package test

f :: proc(a: int, b: int) {}

main :: proc(s: []int) {
	f(..s)
}
`,
			{},
		},
		{
			"a c_vararg foreign procedure",
			`package test

foreign import lib "system:c"

foreign lib {
	printf :: proc(format: cstring, #c_vararg args: ..any) -> i32 ---
}

main :: proc() {
	printf("a", 1, 2)
}
`,
			{},
		},
		{
			"an overloaded group",
			`package test

add_int :: proc(a, b: int) -> int {
	return a + b
}

add_f32 :: proc(a, b: f32) -> f32 {
	return a + b
}

add :: proc {
	add_int,
	add_f32,
}

main :: proc() {
	_ = add(1)
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_call_arity = true})
}

@(test)
argument_count_uses_same_platform_declaration :: proc(t: ^testing.T) {
	// Corpus: tina src/sys_thread_linux.odin:88, see docs/corpus-validation.md.
	source := test.Source {
		main = `#+build linux
package test

setname :: proc(id: u64, name: cstring) {}
f :: proc() { setname(0, "x") }
`,
		files = {{name = "a.odin", source = `#+build darwin
package test

setname :: proc(name: cstring) {}
`}},
		config = {enable_lint_call_arity = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
argument_count_skips_file_the_host_does_not_build :: proc(t: ^testing.T) {
	// Corpus: core/net socket_linux.odin:163 on darwin, see docs/corpus-validation.md.
	source := test.Source {
		main = `#+build linux
package test

f :: proc() { h(1) }
`,
		files = {
			{name = "b.odin", source = "#+build linux\npackage test\n\nh :: proc(x: int) {}\n"},
			{name = "a.odin", source = "#+build darwin\npackage test\n\nh :: proc() {}\n"},
		},
		config = {enable_lint_call_arity = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
argument_count_expands_multi_value_call_argument :: proc(t: ^testing.T) {
	// Corpus: core io/multi.odin:16 and os/file_util.odin:66 on the S17 rerun, see docs/corpus-validation.md.
	// Odin expands a call that returns several values into that many arguments. The cases at the end keep real arity errors and an #optional_ok result as one argument.
	cases := []Lint_Case {
		{
			"a call that returns two values fills two parameters",
			`package test

pair :: proc() -> (int, bool) { return 1, true }

take :: proc(n: int, ok: bool) -> int { return n }

main :: proc() {
	_ = take(pair())
}
`,
			{},
		},
		{
			"a multi-value call followed by more arguments",
			`package test

pair :: proc() -> (int, bool) { return 1, true }

take :: proc(n: int, ok: bool, out: ^int) -> bool { return ok }

main :: proc() {
	x: int
	_ = take(pair(), &x)
}
`,
			{},
		},
		{
			"a multi-value call still leaves the call short or long",
			`package test

pair :: proc() -> (int, bool) { return 1, true }

take :: proc(n: int, ok: bool) -> int { return n }

main :: proc() {
	_ = take(pair(), 1)
}
`,
			{{7, "argument-count"}},
		},
		{
			"an optional_ok result is one argument",
			`package test

maybe :: proc() -> (n: int, ok: bool) #optional_ok { return 1, true }

take :: proc(n: int, m: int) -> int { return n }

main :: proc() {
	_ = take(maybe(), maybe())
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_call_arity = true})
}

@(test)
argument_count_skips_unknown_result_counts :: proc(t: ^testing.T) {
	// A procedure group or an unresolved callee passes an unknown number of values, unless every member agrees.
	cases := []Lint_Case {
		{
			"a group whose members all return two values fills two parameters",
			`package test

pair_none :: proc() -> (int, bool) { return 1, true }
pair_one :: proc(x: int) -> (int, bool) { return x, true }
pair :: proc { pair_none, pair_one }

take :: proc(n: int, ok: bool) -> int { return n }

main :: proc() {
	_ = take(pair())
}
`,
			{},
		},
		{
			"a group whose members disagree hides the count",
			`package test

one :: proc() -> int { return 1 }
two :: proc(x: int) -> (int, bool) { return x, true }
mixed :: proc { one, two }

take :: proc(n: int, ok: bool) -> int { return n }

main :: proc() {
	_ = take(mixed())
}
`,
			{},
		},
		{
			"an unresolved callee hides the count",
			`package test

take :: proc(n: int, ok: bool) -> int { return n }

main :: proc() {
	_ = take(missing())
}
`,
			{},
		},
		{
			"a group member that never fit the call",
			`package test

one :: proc(a: int) {}
two :: proc(a: Missing, b: int) {}
g :: proc { one, two }

main :: proc() {
	g(1, 2)
}
`,
			{},
		},
		{
			"a group member whose arity cannot fit the call",
			`package test

h :: proc(x: int) {}
one :: proc(a: int) -> (int, int) { return 1, 2 }
two :: proc(a: int, b: Missing) -> int { return 1 }
g :: proc { one, two }

main :: proc(y: int) {
	h(g(1, y))
}
`,
			{},
		},
		{
			"a group member that needs more arguments than the argument passes",
			`package test

one :: proc(a: Missing) -> (int, int) { return 1, 2 }
two :: proc(a, b: int) -> int { return a }
g :: proc { one, two }

h2 :: proc(a, b: int) {}

main :: proc() {
	h2(g(1))
}
`,
			{},
		},
		{
			"a group member that needs more arguments than a call with an arrow call argument passes",
			`package test

one :: proc(a: int, b: int) {}
two :: proc(a: Missing) {}
g :: proc { one, two }

Obj :: struct {
	single: proc(o: ^Obj) -> int,
}

main :: proc() {
	x: ^Obj
	g(x->single())
}
`,
			{},
		},
		{
			"a call of a value of a poly type hides the count",
			`package test

take :: proc(a, b: int) {}

f :: proc(fp: $F) {
	take(fp())
}
`,
			{},
		},
		{
			"a conversion to a procedure type passes one value",
			`package test

Cb :: proc() -> (int, int)
f :: proc() -> (int, int) { return 1, 2 }
one :: proc(a: int) {}
take :: proc(a, b: int) {}

main :: proc(p: Cb) {
	v: Cb = f
	one(Cb(f))
	take(v())
	take(p())
	take(Cb(f))
	one(v())
}
`,
			{{12, "argument-count"}, {13, "argument-count"}},
		},
		{
			"a result field with several names passes one value per name",
			`package test

pair :: proc() -> (a, b: int) { return 1, 2 }
one :: proc(a: int) {}
two :: proc(a, b: int) {}
g :: proc { one, two }

main :: proc() {
	g(pair())
}
`,
			{},
		},
		{
			"an optional-ok call passes one value to a group",
			`package test

maybe :: proc() -> (n: int, ok: bool) #optional_ok { return 1, true }
one :: proc(a: int) {}
two :: proc(a: int, b: bool) {}
g :: proc { one, two }

main :: proc() {
	g(maybe())
}
`,
			{},
		},
		{
			"an arrow call argument passes every result to a group",
			`package test

one :: proc(a: int) {}
two :: proc(a, b: int) {}
g :: proc { one, two }

Obj :: struct {
	pair: proc(o: ^Obj) -> (int, int),
}

main :: proc() {
	x: ^Obj
	g(x->pair())
}
`,
			{},
		},
		{
			"an arrow call passes every result",
			`package test

Obj :: struct {
	pair: proc(o: ^Obj) -> (int, int),
}

take :: proc(a, b: int) {}

main :: proc() {
	x: ^Obj
	take(x->pair())
	take(1, x->pair())
}
`,
			{{11, "argument-count"}},
		},
		{
			"a group member that needs more arguments than the call passes",
			`package test

one :: proc(a: int, b: int) {}
two :: proc(a: Missing) {}
g :: proc { one, two }

main :: proc() {
	g(1)
}
`,
			{},
		},
		{
			"a group whose overload does not resolve still counts when its members agree",
			`package test

data_slice :: proc(value: []$E) -> [^]E { return nil }
data_string :: proc(value: string) -> [^]byte { return nil }
data :: proc { data_slice, data_string }

f :: proc(a, b: int) {}

g :: proc(slice: $S/[]$E) {
	f(1, 2, data(slice))
}
`,
			{{9, "argument-count"}},
		},
		{
			"a conversion argument still counts as one value",
			`package test

take :: proc(p: ^int) {}

main :: proc(r: rawptr) {
	take((^int)(r), 1)
}
`,
			{{5, "argument-count"}},
		},
		{
			"a wrong-arity call through an alias",
			`package test

one :: proc(a: int) {}
alias :: one

main :: proc() {
	alias(1, 2)
}
`,
			{{6, "argument-count"}},
		},
		{
			"a direct call with the wrong count still reports",
			`package test

one :: proc(a: int) {}
g :: proc { one }

main :: proc() {
	one(1, 2)
}
`,
			{{6, "argument-count"}},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_call_arity = true})
}

@(test)
argument_count_expands_call_of_unnamed_callee :: proc(t: ^testing.T) {
	// A callee that is not a name, such as a call or an index, still passes every result of the procedure it yields.
	cases := []Lint_Case {
		{
			"a call of a returned procedure",
			`package test

h :: proc() -> proc() -> (int, int) { return nil }
two :: proc(a, b: int) {}

main :: proc() {
	two(h()())
}
`,
			{},
		},
		{
			"a call of an array element and of a parenthesized name",
			`package test

pair :: proc() -> (int, int) { return 1, 2 }
two :: proc(a, b: int) {}

main :: proc() {
	arr: [2]proc() -> (int, int)
	two(arr[0]())
	two((pair)())
}
`,
			{},
		},
		{
			"a call of a returned procedure still counts its results exactly",
			`package test

h :: proc() -> proc() -> (int, int) { return nil }
one :: proc(a: int) {}

main :: proc() {
	one(h()())
}
`,
			{{6, "argument-count"}},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_call_arity = true})
}
