package tests

import "core:strings"
import "core:testing"

import "src:common"
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
	for _ in 0 ..< len(xs) {
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
	_, unknown, ok := server.modernize_select({"nested-if", "no-such-rule"}, &common.config)
	testing.expect(t, !ok && unknown == "no-such-rule")

	selected, _, _ := server.modernize_select({}, &common.config)
	testing.expect(t, "nested-if" in selected && "use-stdlib/contains" in selected)
	testing.expect(t, "use-stdlib/copy-loop" not_in selected && "self-assignment" not_in selected)
	testing.expect(t, "redundant-else" in selected)
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
	for rule in server.modernize_rules(&common.config) do ids[rule.id] = true

	testing.expect_value(t, len(server.SIMPLIFY_CODES), server.simplify_rule_count())
	for code in server.SIMPLIFY_CODES {
		testing.expectf(t, code in ids, "simplify code %s is not a modernize rule", code)
	}
	for rule in server.stdlib_rules() {
		name, _ := strings.replace_all(rule.name, "_", "-", context.temp_allocator)
		id := strings.concatenate({"use-stdlib/", name}, context.temp_allocator)
		testing.expectf(t, id in ids, "use_stdlib rule %s is not a modernize rule", id)
	}
	selected, _, _ := server.modernize_select({}, &common.config)
	for id in ([]string{"use-stdlib/clamp-if", "use-stdlib/max-lt", "use-stdlib/min-else", "use-stdlib/abs-lt"}) {
		testing.expectf(t, id in ids && id not_in selected, "%s should be a non-default rule", id)
	}
	testing.expect(t, "file-tags" in ids && "file-tags" not_in selected, "file-tags should be a non-default rule")
	free_all(context.temp_allocator)
}

@(test)
modernize_or_break_or_continue :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

Error :: union {
	int,
}

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(i: int) -> bool {
	return i > 0
}

h :: proc(i: int) -> (int, Error) {
	return i, nil
}

loops :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v, ok := f(x)
		if !ok {
			break
		}
		total += v
	}
	for x in xs {
		v, err := h(x)
		if err != nil {
			continue
		}
		total += v
	}
	outer: for x in xs {
		for y in xs {
			ok := g(x + y)
			if !ok {
				continue outer
			}
			total += y
		}
	}
	for x in xs {
		switch x {
		case 0:
			v, ok := f(x)
			if !ok {
				break
			}
			total += v
		}
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_modernized(
		t,
		&src,
		{},
		`package test

Error :: union {
	int,
}

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(i: int) -> bool {
	return i > 0
}

h :: proc(i: int) -> (int, Error) {
	return i, nil
}

loops :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v := f(x) or_break
		total += v
	}
	for x in xs {
		v := h(x) or_continue
		total += v
	}
	outer: for x in xs {
		for y in xs {
			g(x + y) or_continue outer
			total += y
		}
	}
	for x in xs {
		switch x {
		case 0:
			v := f(x) or_break
			total += v
		}
	}
	return total
}
`,
	)
}

// Corpus: tina src/extensions/http/server/body.odin:841, see docs/corpus-validation.md.
@(test)
modernize_fill_broadcasts_fixed_array :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

E :: enum {
	A,
	B,
}

f :: proc() -> [8]u8 {
	buf: [8]u8
	for i in 0 ..< len(buf) {
		buf[i] = 'a'
	}
	return buf
}

g :: proc() -> [E]int {
	offs: [E]int
	for &d in offs {
		d = -1
	}
	return offs
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	// A fixed array takes the value by broadcast. An enumerated array cannot be sliced, nor
	// broadcast an untyped constant, so its loop stays.
	test.expect_modernized(
		t,
		&src,
		{},
		`package test

E :: enum {
	A,
	B,
}

f :: proc() -> [8]u8 {
	buf: [8]u8
	buf = 'a'
	return buf
}

g :: proc() -> [E]int {
	offs: [E]int
	for &d in offs {
		d = -1
	}
	return offs
}
`,
	)
}

// Corpus: reduced (tina review), see docs/corpus-validation.md.
@(test)
modernize_fill_skips_value_using_index :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

idx :: proc(s: []int) {
	for i in 0 ..< len(s) {
		s[i] = i
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(
		t,
		&src,
		{},
		`package test

idx :: proc(s: []int) {
	for i in 0 ..< len(s) {
		s[i] = i
	}
}
`,
	)
}

// Corpus: Skald examples/40_threads/main.odin:72, see docs/corpus-validation.md.
@(test)
modernize_sum_skips_interval_range :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

total :: proc() -> int {
	t := 0
	for i in 1 ..= 10 {
		t += i
	}
	return t
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(
		t,
		&src,
		{},
		`package test

total :: proc() -> int {
	t := 0
	for i in 1 ..= 10 {
		t += i
	}
	return t
}
`,
	)
}

// Corpus: reduced (ols review), see docs/corpus-validation.md.
@(test)
modernize_redundant_parens_keeps_comment :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(k: string) -> bool {
	return (
		// first
		k != "a" &&
		k != "b")
}
`,
		config = {enable_lint_simplify = true},
	}

	// Keeping the comment inside a rewritten return would also be correct; then update the expected text.
	test.expect_modernized(
		t,
		&src,
		{"redundant-parens"},
		`package test

f :: proc(k: string) -> bool {
	return (
		// first
		k != "a" &&
		k != "b")
}
`,
	)
}

// Corpus: Skald runa itemize (GB999 comment), see docs/corpus-validation.md.
@(test)
modernize_bool_return_keeps_comment :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(a, b: int) -> bool {
	if a == b {
		return false
	}

	// Rule 999: default is to break.
	return true
}
`,
		config = {enable_lint_simplify = true},
	}

	// Keeping the comment above a rewritten return would also be correct; then update the expected text.
	test.expect_modernized(
		t,
		&src,
		{"bool-return"},
		`package test

f :: proc(a, b: int) -> bool {
	if a == b {
		return false
	}

	// Rule 999: default is to break.
	return true
}
`,
	)
}

// Corpus: tina scripts/check_test_hygiene.odin:1112, see docs/corpus-validation.md.
@(test)
modernize_nested_if_one_line_body_indents_with_tabs :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(a, b: bool) -> int {
	if a {
		if b { return 1 }
	}
	return 0
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_modernized(
		t,
		&src,
		{"nested-if"},
		`package test

f :: proc(a, b: bool) -> int {
	if a && b {
		return 1
	}
	return 0
}
`,
	)
}

// Corpus: core encoding/json/unmarshal.odin:450. Odin rejects an unparenthesised `or_return` operand.
@(test)
modernize_nested_if_wraps_or_return :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc() -> (bool, bool) {
	return true, false
}

g :: proc(a: bool) -> (err: bool) {
	if a {
		if f() or_return {
			return
		}
	}
	return
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_modernized(
		t,
		&src,
		{"nested-if"},
		`package test

f :: proc() -> (bool, bool) {
	return true, false
}

g :: proc(a: bool) -> (err: bool) {
	if a && (f() or_return) {
		return
	}
	return
}
`,
	)
}

// Corpus: core slice/slice.odin:159. Inside package slice, `slice.linear_search` is the
// procedure itself, so the rewrite would recurse and import its own package.
@(test)
modernize_use_stdlib_skips_own_package :: proc(t: ^testing.T) {
	text := `package slice

linear_search :: proc(array: []$T, key: T) -> (index: int, found: bool) {
	for x, i in array {
		if x == key {
			return i, true
		}
	}
	return -1, false
}
`
	src := test.Source {
		main = text,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(t, &src, {"use-stdlib/linear-search"}, text)
}

// A fixed array needs a slice expression before it reaches a slice parameter, and only an
// addressable value has one.
@(test)
modernize_sum_slices_fixed_array :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

make_arr :: proc() -> [4]int {
	return {}
}

f :: proc() -> int {
	arr: [4]int
	total := 0
	for x in arr {
		total += x
	}
	return total
}

g :: proc() -> int {
	total := 0
	for x in make_arr() {
		total += x
	}
	return total
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(
		t,
		&src,
		{},
		`package test

import "core:math"

make_arr :: proc() -> [4]int {
	return {}
}

f :: proc() -> int {
	arr: [4]int
	return math.sum(arr[:])
}

g :: proc() -> int {
	total := 0
	for x in make_arr() {
		total += x
	}
	return total
}
`,
	)
}

@(test)
modernize_keeps_comment_inside_rewritten_range :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(s: []int, x: int) -> bool {
	for e in s {
		// look
		if e == x {
			return true
		}
	}
	return false
}

g :: proc(n: int) -> int {
	n := n
	n = n + /* one */ 1
	return n
}
`,
		config = {enable_lint_use_stdlib = true, enable_lint_simplify = true},
	}

	test.expect_modernized(t, &src, {}, src.main)
}

// A lint fix whose replacement drops a comment is skipped, and the same fix without one applies.
@(test)
modernize_lint_fix_keeps_comment :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(a: int) -> int {
	b := a + /* pad */ 0
	c := a + 0
	return b + c
}
`,
		config = {enable_lint_no_op = true},
	}

	test.expect_modernized(
		t,
		&src,
		{"no-op-arithmetic"},
		`package test

f :: proc(a: int) -> int {
	b := a + /* pad */ 0
	c := a
	return b + c
}
`,
	)
}

// Odin rejects `x[:]` on a constant, a by-value parameter and a range value, so the loop stays.
@(test)
modernize_sum_skips_fixed_array_parameter :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(a: [4]int) -> int {
	total := 0
	for x in a {
		total += x
	}
	return total
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(t, &src, {}, src.main)
}

@(test)
modernize_sum_skips_fixed_array_constant :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

C :: [3]int{1, 2, 3}

f :: proc() -> int {
	total := 0
	for x in C {
		total += x
	}
	return total
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(t, &src, {}, src.main)
}

@(test)
modernize_sum_skips_fixed_array_range_value :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(grid: [2][3]int) -> int {
	out := 0
	for row in grid {
		total := 0
		for x in row {
			total += x
		}
		out += total
	}
	return out
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(t, &src, {}, src.main)
}

@(test)
modernize_unused_parameter_keeps_a_named_argument :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(a: int, b: int, hidden := false) -> int {
	return a
}

g :: proc() -> int {
	return f(1, 2, hidden = true)
}
`,
		config = {enable_lint_unused_parameter = true},
	}

	test.expect_modernized(t, &src, {"unused-parameter"}, `package test

f :: proc(a: int, _: int, hidden := false) -> int {
	return a
}

g :: proc() -> int {
	return f(1, 2, hidden = true)
}
`)
}

// Sweep: an untyped value assigned to every element of a fixed array names the element type.
@(test)
modernize_fill_broadcasts_untyped_values :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

S :: struct {
	a: int,
}

E :: enum {
	A,
	B,
}

U :: union {
	int,
	f32,
}

arr: [4]S
es: [4]E
ps: [4]^int
us: [4]U
ms: [4]matrix[2, 2]f32

f :: proc() {
	sizes: [4][2]int
	for &s in sizes {
		s = {1, 2}
	}
	for &c in arr {
		c = {}
	}
	for &c in es {
		c = .B
	}
	for &p in ps {
		p = nil
	}
	for &u in us {
		u = nil
	}
	for &m in ms {
		m = 1
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	// Odin does not broadcast nil into a union, nor an untyped constant into a matrix.
	test.expect_modernized(
		t,
		&src,
		{},
		`package test

import "core:slice"

S :: struct {
	a: int,
}

E :: enum {
	A,
	B,
}

U :: union {
	int,
	f32,
}

arr: [4]S
es: [4]E
ps: [4]^int
us: [4]U
ms: [4]matrix[2, 2]f32

f :: proc() {
	sizes: [4][2]int
	sizes = [2]int{1, 2}
	arr = S{}
	es = E.B
	ps = nil
	slice.fill(us[:], nil)
	slice.fill(ms[:], 1)
}
`,
	)
}

// Sweep: slice.fill takes its value as the element type, so an untyped value names it, or the
// loop stays when the type has no name.
@(test)
modernize_fill_types_untyped_values :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

E :: enum {
	A,
	B,
}

f :: proc(sizes: [][2]int, es: []E, anon: []struct {
		a: int,
	}, ptrs: []^int) {
	for &s in sizes {
		s = {1, 2}
	}
	for &c in es {
		c = .B
	}
	for &c in anon {
		c = {}
	}
	for &p in ptrs {
		p = {}
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(
		t,
		&src,
		{},
		`package test

import "core:slice"

E :: enum {
	A,
	B,
}

f :: proc(sizes: [][2]int, es: []E, anon: []struct {
		a: int,
	}, ptrs: []^int) {
	slice.fill(sizes, [2]int{1, 2})
	slice.fill(es, E.B)
	for &c in anon {
		c = {}
	}
	for &p in ptrs {
		p = {}
	}
}
`,
	)
}

// Sweep: a new core import goes among the core imports in sorted order, not after the last import.
@(test)
modernize_import_joins_its_collection :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

import "core:fmt"
import "core:testing"

import "vendor:raylib"

f :: proc(s: []int, x: int) -> bool {
	fmt.println(raylib.WHITE)
	_ = testing.T
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

import "core:fmt"
import "core:slice"
import "core:testing"

import "vendor:raylib"

f :: proc(s: []int, x: int) -> bool {
	fmt.println(raylib.WHITE)
	_ = testing.T
	return slice.contains(s, x)
}
`,
	)
}

// Review: a pointer to a fixed array takes slice.fill through `p[:]`, never a broadcast, and a
// #soa array takes neither.
@(test)
modernize_fill_pointer_and_soa_arrays :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

S :: struct {
	ptr: ^[4]int,
}

f :: proc() {
	s: S
	buf: [8]u8
	p := &buf
	for i in 0 ..< len(p) {
		p[i] = 0
	}
	for &e in s.ptr {
		e = 1
	}
	soa: #soa[4]struct {
		x: int,
	}
	for &e in soa {
		e = {}
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(
		t,
		&src,
		{},
		`package test

import "core:slice"

S :: struct {
	ptr: ^[4]int,
}

f :: proc() {
	s: S
	buf: [8]u8
	p := &buf
	slice.fill(p[:], 0)
	slice.fill(s.ptr[:], 1)
	soa: #soa[4]struct {
		x: int,
	}
	for &e in soa {
		e = {}
	}
}
`,
	)
}

// Review: a value that reads the array changes as the loop writes it, so the loop stays.
@(test)
modernize_fill_skips_value_reading_array :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

arr: [4]int
xs: []int

f :: proc() {
	for &e in arr {
		e = arr[0] * 2
	}
	for i in 0 ..< len(xs) {
		xs[i] = xs[0] + 1
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_modernized(t, &src, {}, src.main)
}
