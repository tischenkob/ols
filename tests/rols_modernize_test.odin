package tests

import "core:strings"
import "core:testing"

import "src:server"
import test "src:testing"

@(test)
modernize_one_import_for_many_fixes :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

import "core:fmt"

has :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e == x {
			return true
		}
	}
	return false
}

has_f :: proc(s: []f32, x: f32) -> bool {
	for e in s {
		if e == x {
			return true
		}
	}
	return false
}

keep :: proc() {
	x := 1
	x = x
	fmt.println(x)
}
`,
		config = {enable_lint_simplify = true, enable_lint_use_stdlib = true, enable_lint_self_assignment = true},
	}

	// The self-assignment fix is not in the default set.
	test.expect_modernized(
		t,
		&src,
		{},
		`package test

import "core:fmt"
import "core:slice"

has :: proc(s: []int, x: int) -> bool {
	return slice.contains(s, x)
}

has_f :: proc(s: []f32, x: f32) -> bool {
	return slice.contains(s, x)
}

keep :: proc() {
	x := 1
	x = x
	fmt.println(x)
}
`,
	)
}

@(test)
modernize_reuses_import_alias :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

import sl "core:slice"

has :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e == x {
			return true
		}
	}
	return false
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(
		t,
		&src,
		{},
		`package test

import sl "core:slice"

has :: proc(s: []int, x: int) -> bool {
	return sl.contains(s, x)
}
`,
	)
}

@(test)
modernize_import_without_imports :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

pre :: proc(s: string, p: string) -> bool {
	return len(s) >= len(p) && s[:len(p)] == p
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(
		t,
		&src,
		{},
		`package test

import "core:strings"

pre :: proc(s: string, p: string) -> bool {
	return strings.has_prefix(s, p)
}
`,
	)
}

// The outer merge wins the overlap in pass 1; the inner one applies in pass 2.
@(test)
modernize_chains_passes :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

g :: proc() {}

f :: proc(a, b, c: bool) {
	if a {
		if b {
			if c {
				g()
			}
		}
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_modernized(
		t,
		&src,
		{"nested-if"},
		`package test

g :: proc() {}

f :: proc(a, b, c: bool) {
	if a && b && c {
		g()
	}
}
`,
		{{rule = "nested-if", pass = 1, line = 6, col = 2}, {rule = "nested-if", pass = 2, line = 6, col = 2}},
	)
}

// Both unused-variable fixes cover the declaration; the removal is the outer fix and wins.
@(test)
modernize_alternative_fixes :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc() {
	x := 1
}
`,
		config = {enable_lint_unused_variable = true},
	}

	test.expect_modernized(
		t,
		&src,
		{"unused-variable/discard", "unused-variable/remove"},
		`package test

f :: proc() {
}
`,
	)
}

@(test)
modernize_review_family :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(y: int) -> int {
	x := y
	x = x
	return x
}
`,
		config = {enable_lint_self_assignment = true, enable_lint_simplify = true},
	}

	test.expect_modernized(t, &src, {"review"}, `package test

f :: proc(y: int) -> int {
	x := y
	return x
}
`)
}

@(test)
modernize_rule_filter :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

g :: proc() {}

f :: proc(a, b: bool, xs: []int) {
	if a {
		if b {
			g()
		}
	}
	for i := 0; i < len(xs); i += 1 {
		g()
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_modernized(
		t,
		&src,
		{"range-loop"},
		`package test

g :: proc() {}

f :: proc(a, b: bool, xs: []int) {
	if a {
		if b {
			g()
		}
	}
	for _ in 0..<len(xs) {
		g()
	}
}
`,
	)
}

@(test)
modernize_rejects_unparsable_pass :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc() {
}
`,
	}

	test.expect_modernize_pass(t, &src, {{rule = "nested-if", start = 26, end = 27, text = "(("}}, false)
}

@(test)
modernize_select_unknown_rule :: proc(t: ^testing.T) {
	_, unknown, ok := server.modernize_select({"nested-if", "no-such-rule"})
	testing.expect(t, !ok && unknown == "no-such-rule")

	selected, _, _ := server.modernize_select({})
	testing.expect(t, "nested-if" in selected && "use-stdlib/contains" in selected)
	testing.expect(t, "use-stdlib/copy-loop" not_in selected && "self-assignment" not_in selected)
	testing.expect(t, "redundant-else" not_in selected)
	free_all(context.temp_allocator)
}

// A fix around the import insertion point waits for a later pass; the fix needing the import stays.
@(test)
modernize_pass_drops_fix_around_import_point :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc() {
}
`,
	}

	test.expect_modernize_pass(
		t,
		&src,
		{
			{rule = "nested-if", start = 0, end = 20, text = "package test\n\nf :: "},
			{rule = "use-stdlib/contains", start = 26, end = 27, text = "{", imports = {"core:slice"}},
		},
		true,
		{"use-stdlib/contains"},
	)
}

// A parameter named like the package would shadow the qualifier.
@(test)
modernize_skips_shadowed_package :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

pre :: proc(strings, p: string) -> bool {
	return len(strings) >= len(p) && strings[:len(p)] == p
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(
		t,
		&src,
		{"idiom"},
		`package test

pre :: proc(strings, p: string) -> bool {
	return len(strings) >= len(p) && strings[:len(p)] == p
}
`,
	)
}

// Every simplify code and use_stdlib rule is registered, so a new rule cannot be missed. Lint fix
// codes live in each lint and are not enumerable.
@(test)
modernize_registers_every_rule :: proc(t: ^testing.T) {
	ids := make(map[string]bool, context.temp_allocator)
	for rule in server.modernize_rules() do ids[rule.id] = true

	testing.expect_value(t, len(server.SIMPLIFY_CODES), server.simplify_rule_count())
	for code in server.SIMPLIFY_CODES {
		testing.expectf(t, code in ids, "simplify code %s is not a modernize rule", code)
	}
	for rule in server.stdlib_rules() {
		name, _ := strings.replace_all(rule.name, "_", "-", context.temp_allocator)
		id := strings.concatenate({"use-stdlib/", name}, context.temp_allocator)
		testing.expectf(t, id in ids, "use_stdlib rule %s is not a modernize rule", id)
	}
	selected, _, _ := server.modernize_select({})
	for id in ([]string{"use-stdlib/clamp-if", "use-stdlib/max-lt", "use-stdlib/min-else", "use-stdlib/abs-lt"}) {
		testing.expectf(t, id in ids && id not_in selected, "%s should be a non-default rule", id)
	}
	testing.expect(t, "file-tags" in ids && "file-tags" not_in selected, "file-tags should be a non-default rule")
	free_all(context.temp_allocator)
}
