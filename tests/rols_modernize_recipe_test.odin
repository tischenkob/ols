#+feature dynamic-literals
package tests

import "core:slice"
import "core:strings"
import "core:testing"

import "src:common"
import "src:server"
import test "src:testing"

@(private = "file")
SORT_PACKAGES := []test.Package {
	{pkg = "sort", source = `package sort
quick_sort :: proc(s: []$T) {}
`},
	{pkg = "slice", source = `package slice
sort :: proc(s: []$T) {}
`},
}

@(private = "file")
SORT_RECIPE := []common.Modernize_Recipe {
	{name = "sort-slice", match = "sort.quick_sort($s)", replace = "slice.sort($s)", imports = {"core:slice"}},
}

@(private = "file")
recipe :: proc(
	t: ^testing.T,
	recipes: []common.Modernize_Recipe,
	main, expected: string,
	rules: []string = {"recipe"},
	packages: []test.Package = nil,
) {
	src := test.Source {
		main = main,
		packages = packages,
		collections = {"core" = "test"},
		config = {modernize_recipes = recipes},
	}
	test.expect_modernized(t, &src, rules, expected)
}

@(test)
modernize_recipe_expression :: proc(t: ^testing.T) {
	recipe(
		t,
		SORT_RECIPE,
		`package test

import "core:sort"

main :: proc() {
	xs := []int{3, 1}
	sort.quick_sort(xs)
	sort.quick_sort((xs))
}
`,
		`package test

import "core:sort"
import "core:slice"

main :: proc() {
	xs := []int{3, 1}
	slice.sort(xs)
	slice.sort(xs)
}
`,
		packages = SORT_PACKAGES,
	)
}

// Recipes are default rules, and a recipe matches through an import alias.
@(test)
modernize_recipe_aliased_import :: proc(t: ^testing.T) {
	recipe(
		t,
		SORT_RECIPE,
		`package test

import srt "core:sort"
import sort "other:sorting"

main :: proc() {
	xs := []int{3, 1}
	srt.quick_sort(xs)
	sort.quick_sort(xs)
}
`,
		`package test

import srt "core:sort"
import sort "other:sorting"
import "core:slice"

main :: proc() {
	xs := []int{3, 1}
	slice.sort(xs)
	sort.quick_sort(xs)
}
`,
		rules = {},
		packages = SORT_PACKAGES,
	)
}

// The replacement writes the alias the file already uses, and a package qualifier of match keeps
// the alias the code wrote.
@(test)
modernize_recipe_reuses_alias :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe {
		SORT_RECIPE[0],
		{name = "stable", match = "sort.quick_sort($s, $f)", replace = "sort.merge_sort($s, $f)"},
	}
	recipe(
		t,
		recipes,
		`package test

import srt "core:sort"
import sl "core:slice"

main :: proc() {
	xs := []int{3, 1}
	srt.quick_sort(xs)
	srt.quick_sort(xs, less)
}
`,
		`package test

import srt "core:sort"
import sl "core:slice"

main :: proc() {
	xs := []int{3, 1}
	sl.sort(xs)
	srt.merge_sort(xs, less)
}
`,
		packages = SORT_PACKAGES,
	)
}

// A fix whose qualifier names another import of the file is dropped.
@(test)
modernize_recipe_qualifier_taken :: proc(t: ^testing.T) {
	src := `package test

import "core:sort"
import slice "other:sort"

main :: proc() {
	xs := []int{3, 1}
	sort.quick_sort(xs)
}
`
	recipe(t, SORT_RECIPE, src, src, packages = SORT_PACKAGES)
}

@(test)
modernize_recipe_repeated_metavariable :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe{{name = "same-min", match = "min($a, $a)", replace = "$a"}}
	recipe(
		t,
		recipes,
		`package test

main :: proc() {
	x, y := 1, 2
	a := min(x, x)
	b := min(x, y)
	c := min(x.y, x .y)
}
`,
		`package test

main :: proc() {
	x, y := 1, 2
	a := x
	b := min(x, y)
	c := x.y
}
`,
	)
}

@(test)
modernize_recipe_where_slice :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe {
		{
			name = "is-empty",
			match = "len($s) == 0",
			replace = "slice.is_empty($s)",
			imports = {"core:slice"},
			where_ = {{var = "s", kind = "slice"}},
		},
	}
	recipe(
		t,
		recipes,
		`package test

S :: struct {
	items: []int,
}

main :: proc() {
	xs: []int
	d: [dynamic]int
	str: string
	s: S
	_ = len(xs) == 0
	_ = len(d) == 0
	_ = len(str) == 0
	_ = len(s.items) == 0
	_ = len(xs[:]) == 0
}
`,
		`package test

import "core:slice"

S :: struct {
	items: []int,
}

main :: proc() {
	xs: []int
	d: [dynamic]int
	str: string
	s: S
	_ = slice.is_empty(xs)
	_ = len(d) == 0
	_ = len(str) == 0
	_ = slice.is_empty(s.items)
	_ = len(xs[:]) == 0
}
`,
	)
}

@(test)
modernize_recipe_where_kinds :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe {
		{name = "map", match = "clear($m)", replace = "clear_map($m)", where_ = {{var = "m", kind = "map"}}},
		{
			name = "dyn",
			match = "clear($d)",
			replace = "clear_dynamic($d)",
			where_ = {{var = "d", kind = "dynamic_array"}},
		},
		{name = "str", match = "len($s)", replace = "byte_len($s)", where_ = {{var = "s", kind = "string"}}},
		{name = "ptr", match = "free($p)", replace = "free_ptr($p)", where_ = {{var = "p", kind = "pointer"}}},
		{name = "fixed", match = "fill($a)", replace = "fill_fixed($a)", where_ = {{var = "a", kind = "fixed_array"}}},
	}
	recipe(
		t,
		recipes,
		`package test

main :: proc() {
	m: map[int]int
	d: [dynamic]int
	s: string
	p: ^int
	a: [4]int
	clear(m)
	clear(d)
	_ = len(s)
	_ = len(a)
	free(p)
	free(d)
	fill(a)
	fill(d)
}
`,
		`package test

main :: proc() {
	m: map[int]int
	d: [dynamic]int
	s: string
	p: ^int
	a: [4]int
	clear_map(m)
	clear_dynamic(d)
	_ = byte_len(s)
	_ = len(a)
	free_ptr(p)
	free(d)
	fill_fixed(a)
	fill(d)
}
`,
	)
}

@(test)
modernize_recipe_statement_sequence :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe {
		{name = "bool-return", match = "if $c {\n\treturn true\n}\nreturn false", replace = "return $c"},
		{name = "swap", match = "$a, $b = $b, $a", replace = "tmp := $a\n$a = $b\n$b = tmp"},
	}
	recipe(
		t,
		recipes,
		`package test

f :: proc(x: int) -> bool {
	if x > 1 || x < -1 {
		return true
	}
	return false
}

g :: proc(x, y: int) {
	x, y := x, y
	for {
		x, y = y, x
	}
}
`,
		`package test

f :: proc(x: int) -> bool {
	return x > 1 || x < -1
}

g :: proc(x, y: int) {
	x, y := x, y
	for {
		tmp := x
		x = y
		y = tmp
	}
}
`,
	)
}

// A compound binding gets parentheses where it is an operand of the replacement.
@(test)
modernize_recipe_parenthesizes_operands :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe{{name = "double", match = "twice($x)", replace = "$x * 2 + f($x)"}}
	recipe(
		t,
		recipes,
		`package test

main :: proc() {
	a, b := 1, 2
	_ = twice(a + b)
	_ = twice(a)
}
`,
		`package test

main :: proc() {
	a, b := 1, 2
	_ = (a + b) * 2 + f(a + b)
	_ = a * 2 + f(a)
}
`,
	)
}

// A binding with a call is rewritten only when the replacement writes it exactly once, and only
// one binding of a match may contain a call.
@(test)
modernize_recipe_call_bindings :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe {
		{name = "once", match = "wrap($x)", replace = "unwrap($x)"},
		{name = "twice", match = "dup($x)", replace = "pair($x, $x)"},
		{name = "dropped", match = "ignore($x)", replace = "0"},
		{name = "both", match = "join($a, $b)", replace = "join2($a, $b)"},
	}
	recipe(
		t,
		recipes,
		`package test

main :: proc() {
	_ = wrap(g())
	_ = dup(g())
	_ = dup(v)
	_ = ignore(g())
	_ = ignore(v)
	_ = join(g(), v)
	_ = join(g(), g())
}
`,
		`package test

main :: proc() {
	_ = unwrap(g())
	_ = dup(g())
	_ = pair(v, v)
	_ = ignore(g())
	_ = 0
	_ = join2(g(), v)
	_ = join(g(), g())
}
`,
	)
}

@(test)
modernize_recipe_bad_recipes_are_skipped :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe {
		{name = "unbound", match = "a($x)", replace = "b($y)"},
		{name = "syntax", match = "a(", replace = "b"},
		{name = "kind", match = "a($x)", replace = "b($x)", where_ = {{var = "x", kind = "list"}}},
		{name = "where-var", match = "a($x)", replace = "b($x)", where_ = {{var = "y", kind = "map"}}},
		{name = "lone", match = "$x", replace = "b($x)"},
		{name = "lone-name", match = "foo", replace = "bar"},
		{name = "field", match = "$x.$f", replace = "g($x)"},
		{name = "implicit-field", match = "f(.$e)", replace = "g()"},
		{name = "literal", match = "a($x)", replace = "b(`one\ntwo`, $x)"},
		{name = "proc-lit", match = "f(proc() {})", replace = "g()"},
		{name = "switch", match = "switch $x {\n}", replace = "g()"},
		{name = "typed", match = "$x: int = $y", replace = "$x := $y"},
		{name = "shape", match = "a($x)", replace = "b($x)\nc()"},
		{name = "good", match = "a($x)\n", replace = "b($x)\n"},
		{name = "good", match = "c()", replace = "d()"},
		{name = "bad name", match = "c()", replace = "d()"},
	}
	recipe(
		t,
		recipes,
		`package test

main :: proc() {
	a(1)
	c()
}
`,
		`package test

main :: proc() {
	b(1)
	c()
}
`,
		rules = {},
	)

	config := common.Config {
		modernize_recipes = recipes,
	}
	errors := server.modernize_recipe_errors(&config)
	expected := []string {
		"recipe unbound: replace uses $y, which match does not bind",
		"recipe syntax: match does not parse: line 2: expected an operand",
		"recipe kind: where kind \"list\" is not slice, dynamic_array, fixed_array, map, string or pointer",
		"recipe where-var: where names $y, which match does not bind",
		"recipe lone: match is a lone name, which matches declarations and fields too",
		"recipe lone-name: match is a lone name, which matches declarations and fields too",
		"recipe field: $f names a field, which a metavariable cannot match",
		"recipe implicit-field: $e names a field, which a metavariable cannot match",
		"recipe literal: replace has a string literal that spans lines",
		"recipe proc-lit: Proc_Lit is not supported in match",
		"recipe switch: Switch_Stmt is not supported in match",
		"recipe typed: match has a typed declaration or a tagged literal or type, which matching does not support",
		"recipe shape: replace must be one expression, as match is",
		"recipe good: another recipe has this name",
		"recipe 16: name \"bad name\" must be letters, digits, '-', '_' or '.'",
	}
	testing.expectf(t, slice.equal(errors, expected), "\nExpected:\n%#v\nGot:\n%#v", expected, errors)

	ids := make(map[string]bool, context.temp_allocator)
	for rule in server.modernize_rules(&config) do ids[rule.id] = rule.family == "recipe" && rule.default
	testing.expect(t, ids["recipe/good"], "recipe/good is a default recipe rule")
	testing.expect(t, "recipe/unbound" not_in ids, "a bad recipe is not a rule")
	testing.expect(t, ids["use-stdlib/contains"] == false && "use-stdlib/contains" in ids, "built-in rules stay")

	_, unknown, ok := server.modernize_select({"recipe/unbound"}, &config)
	testing.expect(t, !ok && unknown == "recipe/unbound", "a bad recipe cannot be selected")
}

// $ inside strings, runes and comments is text, not a metavariable.
@(test)
modernize_recipe_dollar_in_literals :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe {
		{name = "price", match = "show(\"$x\", $v) // $c", replace = "show2(\"$x\", '$', $v) /* $d */"},
	}
	recipe(
		t,
		recipes,
		`package test

main :: proc() {
	show("$x", 1)
	show("$y", 1)
}
`,
		`package test

main :: proc() {
	show2("$x", '$', 1) /* $d */
	show("$y", 1)
}
`,
	)
}

// A qualifier of match names only an import, and only where no local declaration shadows it.
@(test)
modernize_recipe_shadowed_qualifier :: proc(t: ^testing.T) {
	src := `package test

import "core:sort"

Sorter :: struct {
	quick_sort: proc(s: []int),
}

f :: proc(sort: Sorter, xs: []int) {
	sort.quick_sort(xs)
}

g :: proc(xs: []int) {
	sort := Sorter{}
	sort.quick_sort(xs)
}
`
	recipe(t, SORT_RECIPE, src, src, packages = SORT_PACKAGES)

	alias := `package test

import srt "core:sort"

Sorter :: struct {
	quick_sort: proc(s: []int),
}

g :: proc(xs: []int) {
	srt := Sorter{}
	srt.quick_sort(xs)
}
`
	recipe(t, SORT_RECIPE, alias, alias, packages = SORT_PACKAGES)

	no_import := `package test

Sorter :: struct {
	quick_sort: proc(s: []int),
}

sort: Sorter

g :: proc(xs: []int) {
	sort.quick_sort(xs)
}
`
	recipe(t, SORT_RECIPE, no_import, no_import, packages = SORT_PACKAGES)
}

// A comment in the matched range survives only inside a binding the replacement writes.
@(test)
modernize_recipe_keeps_comments :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe {
		{name = "once", match = "wrap($x, $y)", replace = "unwrap($x)"},
		{name = "seq", match = "a()\nb()", replace = "c()"},
	}
	recipe(
		t,
		recipes,
		`package test

main :: proc() {
	_ = wrap(x /* kept */ + 1, y)
	_ = wrap(x, /* lost */ y)
	_ = wrap(x, y /* lost */)
	a()
	// lost
	b()
}
`,
		`package test

main :: proc() {
	_ = unwrap(x /* kept */ + 1)
	_ = wrap(x, /* lost */ y)
	_ = wrap(x, y /* lost */)
	a()
	// lost
	b()
}
`,
	)
}

// or_return, or_break and or_continue leave the procedure or loop, so they count as calls.
@(test)
modernize_recipe_control_flow_bindings :: proc(t: ^testing.T) {
	recipes := []common.Modernize_Recipe {
		{name = "dropped", match = "ignore($x)", replace = "0"},
		{name = "twice", match = "dup($x)", replace = "pair($x, $x)"},
		{name = "once", match = "wrap($x)", replace = "unwrap($x)"},
		{name = "both", match = "join($a, $b)", replace = "join2($a, $b)"},
	}
	recipe(
		t,
		recipes,
		`package test

f :: proc(u: union {
		int,
	}) -> bool {
	_ = ignore(u.(int) or_return)
	_ = dup(u.(int) or_return)
	_ = wrap(u.(int) or_return)
	_ = join(u.(int) or_return, g())
	for {
		_ = ignore(u.(int) or_break)
		_ = ignore(u.(int) or_continue)
	}
	return true
}
`,
		`package test

f :: proc(u: union {
		int,
	}) -> bool {
	_ = ignore(u.(int) or_return)
	_ = dup(u.(int) or_return)
	_ = unwrap(u.(int) or_return)
	_ = join(u.(int) or_return, g())
	for {
		_ = ignore(u.(int) or_break)
		_ = ignore(u.(int) or_continue)
	}
	return true
}
`,
	)
}

@(test)
modernize_recipe_node_kinds :: proc(t: ^testing.T) {
	Case :: struct {
		match, replace, code, expected: string,
	}
	cases := []Case {
		{"cast(int)$x", "int($x)", "_ = cast(int)y", "_ = int(y)"},
		{"cast(int)$x", "int($x)", "_ = transmute(int)y", "_ = transmute(int)y"},
		{"auto_cast $x", "cast_auto($x)", "_ = auto_cast y", "_ = cast_auto(y)"},
		{"size_of([]$T)", "slice_size($T)", "_ = size_of([]int)", "_ = slice_size(int)"},
		{"size_of([]$T)", "slice_size($T)", "_ = size_of([4]int)", "_ = size_of([4]int)"},
		{"size_of([dynamic]$T)", "dyn_size($T)", "_ = size_of([dynamic]int)", "_ = dyn_size(int)"},
		{"size_of(map[$K]$V)", "map_size($K, $V)", "_ = size_of(map[int]string)", "_ = map_size(int, string)"},
		{"size_of(^$T)", "ptr_size($T)", "_ = size_of(^int)", "_ = ptr_size(int)"},
		{"size_of(^$T)", "ptr_size($T)", "_ = size_of([^]int)", "_ = size_of([^]int)"},
		{"$a or_else $b", "or_default($a, $b)", "_ = m[k] or_else 0", "_ = or_default(m[k], 0)"},
		{"T{$x}", "make_t($x)", "_ = T{1}", "_ = make_t(1)"},
		{"T{$x}", "make_t($x)", "_ = T{1, 2}", "_ = T{1, 2}"},
		{"T{a = $x}", "T{b = $x}", "_ = T{a = 1}", "_ = T{b = 1}"},
		{"f(.Foo)", "f(.Bar)", "f(.Foo)\n\tf(.Baz)", "f(.Bar)\n\tf(.Baz)"},
		{"$c ? $a : $b", "choose($c, $a, $b)", "_ = x > 0 ? 1 : 2", "_ = choose(x > 0, 1, 2)"},
		{"$c ? $a : $b", "choose($c, $a, $b)", "_ = 1 if x > 0 else 2", "_ = choose(x > 0, 1, 2)"},
		{"$p^", "deref($p)", "_ = p^", "_ = deref(p)"},
		{"{\n\t$x = 0\n}", "$x = 1", "{\n\t\ty = 0\n\t}\n\t_ = T{a = 0}", "y = 1\n\t_ = T{a = 0}"},
		{
			"make([]$T, $n, context.allocator)",
			"make_slice($T, $n)",
			"_ = make([]int, 4, context.allocator)\n\t_ = make([]int, 4, context.temp_allocator)",
			"_ = make_slice(int, 4)\n\t_ = make([]int, 4, context.temp_allocator)",
		},
		{"$u.(int)", "as_int($u)", "_ = v.(int)\n\t_ = v.(f32)", "_ = as_int(v)\n\t_ = v.(f32)"},
	}
	for c in cases {
		recipes := []common.Modernize_Recipe{{name = "case", match = c.match, replace = c.replace}}
		main := strings.concatenate({"package test\n\nmain :: proc() {\n\t", c.code, "\n}\n"}, context.temp_allocator)
		expected := strings.concatenate(
			{"package test\n\nmain :: proc() {\n\t", c.expected, "\n}\n"},
			context.temp_allocator,
		)
		recipe(t, recipes, main, expected)
	}
}
