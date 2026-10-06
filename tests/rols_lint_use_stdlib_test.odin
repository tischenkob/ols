package tests

import "core:fmt"
import "core:testing"

import "src:server"
import test "src:testing"

@(test)
lint_use_stdlib_contains :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: []int, x: int) -> bool {
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

	test.expect_lint_diagnostics(t, &src, {{3, "use_stdlib"}})
}

@(test)
lint_use_stdlib_tags :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: []int, x: int) -> bool {
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

	test.expect_lint_tags(t, &src, {.Unnecessary})
}

@(test)
lint_use_stdlib_has_prefix :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: string, p: string) {
	if len(s) >= len(p) && s[:len(p)] == p {
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {{3, "use_stdlib"}})
}

@(test)
lint_use_stdlib_assign_form :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(a, b: int) {
	r := 0
	if a < b {
		r = a
	} else {
		r = b
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {{4, "use_stdlib"}})
}

@(test)
lint_use_stdlib_mixed_form :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(a, b: int) -> int {
	r := 0
	if a < b {
		r = a
	} else {
		return b
	}
	return r
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {})
}

@(test)
lint_use_stdlib_copy_and_fill :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(dst, source: []int, v: int) {
	for i in 0 ..< len(source) {
		dst[i] = source[i]
	}
	for &e in dst {
		e = v
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {{3, "use_stdlib"}, {6, "use_stdlib"}})
}

@(test)
lint_use_stdlib_sum :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: []int) -> int {
	total := 0
	for x in s {
		total += x
	}
	return total
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {{3, "use_stdlib"}})
}

@(test)
lint_use_stdlib_sum_without_return :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: []int) {
	total := 0
	for x in s {
		total += x
	}
	print(total)
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {{3, "use_stdlib"}})
}

@(test)
lint_use_stdlib_no_match :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e == x {
			return false
		}
	}
	return false
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {})
}

@(test)
lint_use_stdlib_disabled :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e == x {
			return true
		}
	}
	return false
}
`,
	}

	test.expect_lint_diagnostics(t, &src, {})
}

// The pattern of every rule is code a user could have written, so each rule matches its own body.
@(test)
lint_use_stdlib_rules_match_themselves :: proc(t: ^testing.T) {
	for rule in server.stdlib_rules() {
		src := test.Source {
			main = fmt.tprintf("package test\n%s", rule.src),
			config = {enable_lint_use_stdlib = true},
		}
		test.expect_lint_diagnostics(t, &src, {{3, "use_stdlib"}})
	}
}

// Corpus: core slice/slice.odin:159 and strings/strings.odin:617. The standard library must not be
// rewritten into calls to itself.
@(test)
lint_use_stdlib_skips_own_package_slice :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package slice

linear_search :: proc(array: []$T, key: T) -> (index: int, found: bool) {
	for x, i in array {
		if x == key {
			return i, true
		}
	}
	return -1, false
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {})
}

@(test)
lint_use_stdlib_skips_own_package_strings :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package strings

has_suffix :: proc(s, suffix: string) -> (result: bool) {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {})
}

@(test)
use_stdlib_action_contains :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e{*} == x {
			return true
		}
	}
	return false
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_action_applied(
		t,
		&src,
		"Replace with slice.contains",
		`package test
import "core:slice"

main :: proc(s: []int, x: int) -> bool {
	return slice.contains(s, x)
}
`,
	)
}

@(test)
use_stdlib_action_existing_alias :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

import sl "core:slice"

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e{*} == x {
			return true
		}
	}
	return false
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_action_applied(
		t,
		&src,
		"Replace with slice.contains",
		`package test

import sl "core:slice"

main :: proc(s: []int, x: int) -> bool {
	return sl.contains(s, x)
}
`,
	)
}

@(test)
use_stdlib_action_min :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(a, b: int) {
	r := 0
	if a{*} < b {
		r = a
	} else {
		r = b
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_action_applied(
		t,
		&src,
		"Replace with min",
		`package test

main :: proc(a, b: int) {
	r := 0
	r = min(a, b)
}
`,
	)
}

@(test)
use_stdlib_action_sum :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(xs: []int) {
	total := 0
	for x in xs {
		total +{*}= x
	}
	print(total)
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_action_applied(
		t,
		&src,
		"Replace with math.sum",
		`package test
import "core:math"

main :: proc(xs: []int) {
	total := math.sum(xs)
	print(total)
}
`,
	)
}

@(test)
use_stdlib_action_has_prefix :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: string, p: string) {
	if len(s) >= len{*}(p) && s[:len(p)] == p {
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_action_applied(
		t,
		&src,
		"Replace with strings.has_prefix",
		`package test
import "core:strings"

main :: proc(s: string, p: string) {
	if strings.has_prefix(s, p) {
	}
}
`,
	)
}

@(test)
use_stdlib_action_outside_match :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: []int, x: int) -> bool {
	y{*} := 1
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

	test.expect_action_missing(t, &src, "Replace with slice.contains")
}

@(test)
lint_use_stdlib_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"a comment in the body",
			`package test

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		// look
		if e == x {
			return true
		}
	}
	return false
}
`,
			{{3, "use_stdlib"}},
		},
		{
			"a do body",
			`package test

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e == x do return true
	}
	return false
}
`,
			{{3, "use_stdlib"}},
		},
		{
			"a reversed loop",
			`package test

main :: proc(s: []int, x: int) -> bool {
	#reverse for e in s {
		if e == x {
			return true
		}
	}
	return false
}
`,
			{},
		},
		{
			"an extra range value",
			`package test

main :: proc(s: []int, x: int) -> bool {
	for e, _ in s {
		if e == x {
			return true
		}
	}
	return false
}
`,
			{},
		},
		{
			"a differently named accumulator",
			`package test

main :: proc(s: []int) -> int {
	acc := 0
	for x in s {
		acc += x
	}
	return acc
}
`,
			{{3, "use_stdlib"}},
		},
		{
			"an extra statement in the body",
			`package test

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e == x {
			return true
		}
		_ = e
	}
	return false
}
`,
			{},
		},
		{
			"swapped comparison operands are not matched",
			`package test

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		if x == e {
			return true
		}
	}
	return false
}
`,
			{},
		},
		{
			"min written with <= is not matched",
			`package test

main :: proc(a, b: int) -> int {
	if a <= b {
		return a
	}
	return b
}
`,
			{},
		},
		{
			"abs on a float",
			`package test

main :: proc(x: f64) -> f64 {
	if x < 0 {
		return -x
	}
	return x
}
`,
			{{3, "use_stdlib"}},
		},
		{
			"clamp written with min and max calls",
			`package test

a :: proc(x, lo, hi: int) -> int {
	return min(max(x, lo), hi)
}

b :: proc(x, lo, hi: int) -> int {
	return max(min(x, hi), lo)
}
`,
			{},
		},
		{
			"a copy loop with an offset",
			`package test

main :: proc(dst, src: []int) {
	for i in 0 ..< len(src) {
		dst[i + 1] = src[i]
	}
}
`,
			{},
		},
		{
			"fill by index",
			`package test

main :: proc(s: []int, v: int) {
	for i in 0 ..< len(s) {
		s[i] = v
	}
}
`,
			{{3, "use_stdlib"}},
		},
		{
			"a sum written out in full",
			`package test

main :: proc(s: []int) -> int {
	total := 0
	for x in s {
		total = total + x
	}
	return total
}
`,
			{},
		},
		{
			"has_suffix",
			`package test

main :: proc(s, p: string) -> bool {
	return len(s) >= len(p) && s[len(s) - len(p):] == p
}
`,
			{{3, "use_stdlib"}},
		},
		{
			"has_prefix without the length guard",
			`package test

main :: proc(s, p: string) -> bool {
	return s[:len(p)] == p
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_use_stdlib = true})
}

@(test)
use_stdlib_action_import_after_comment :: proc(t: ^testing.T) {
	src := test.Source {
		main = `// header
package test

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e{*} == x {
			return true
		}
	}
	return false
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_action_applied(
		t,
		&src,
		"Replace with slice.contains",
		`// header
package test
import "core:slice"

main :: proc(s: []int, x: int) -> bool {
	return slice.contains(s, x)
}
`,
	)
}

@(test)
use_stdlib_action_twice :: proc(t: ^testing.T) {
	cases := []Fix_Twice {
		{
			"use_stdlib contains",
			"Replace with slice.contains",
			`package test

main :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e{*} == x {
			return true
		}
	}
	return false
}
`,
			"slice.contains(s, x)",
		},
	}

	expect_fix_twice(t, cases, {enable_lint_use_stdlib = true})
}

// max would call next once where the code calls it twice.
@(test)
lint_use_stdlib_call_argument :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

next :: proc() -> int {
	return 1
}

main :: proc() -> int {
	if next() < 5 {
		return 5
	}
	return next()
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {})
}

@(test)
use_stdlib_action_not_offered_over_comment :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

main :: proc(s: []int, x: int) -> bool {
	{*}for e in s {
		// look
		if e == x {
			return true
		}
	}
	return false
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_action_missing(t, &src, "Replace with slice.contains")
}

// Sweep: a fixed array takes the fill value by broadcast, and an untyped value names the element type.
@(test)
use_stdlib_action_fill_broadcasts_fixed_array :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc() {
	sizes: [4][2]int
	for &s in sizes {
		s{*} = {1, 2}
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_action_applied(
		t,
		&src,
		"Replace with array assignment",
		`package test

f :: proc() {
	sizes: [4][2]int
	sizes = [2]int{1, 2}
}
`,
	)
}

// Sweep: the new import goes among the imports of its collection in sorted order.
@(test)
use_stdlib_action_import_joins_its_collection :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

import "core:fmt"
import "core:testing"

import "vendor:raylib"

f :: proc(sizes: [][2]int) {
	fmt.println(raylib.WHITE)
	_ = testing.T
	for &s in sizes {
		s{*} = {1, 2}
	}
}
`,
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_action_applied(
		t,
		&src,
		"Replace with slice.fill",
		`package test

import "core:fmt"
import "core:slice"
import "core:testing"

import "vendor:raylib"

f :: proc(sizes: [][2]int) {
	fmt.println(raylib.WHITE)
	_ = testing.T
	slice.fill(sizes, [2]int{1, 2})
}
`,
	)
}

// Review: enable_add_import_to_bottom puts the import at the end of the file, before the sorted placement.
@(test)
use_stdlib_action_import_to_bottom :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

import "core:fmt"
import "core:testing"

f :: proc(s: []int, x: int) -> bool {
	fmt.println(testing.T)
	for e in s {
		if e{*} == x {
			return true
		}
	}
	return false
}
`,
		config = {enable_lint_use_stdlib = true, enable_add_import_to_bottom = true},
	}

	test.expect_action_applied(
		t,
		&src,
		"Replace with slice.contains",
		`package test

import "core:fmt"
import "core:testing"

f :: proc(s: []int, x: int) -> bool {
	fmt.println(testing.T)
	return slice.contains(s, x)
}

import "core:slice"`,
	)
}

// A pointer to an array slices through `p[:]`, even when a by-value parameter holds it.
@(test)
modernize_fill_slices_pointer_field_of_parameter :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

S :: struct {
	ptr: ^[3]int,
}

f :: proc(s: S) {
	for &e in s.ptr {
		e = 1
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
	ptr: ^[3]int,
}

f :: proc(s: S) {
	slice.fill(s.ptr[:], 1)
}
`,
	)
}

// A value that reads the array through a pointer changes as the loop writes, and a type-switch
// binding is a copy that Odin does not slice.
@(test)
lint_use_stdlib_refuses_alias_and_switch_binding :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"fill value through a pointer to the array",
			`package test

f :: proc() {
	arr: [3]int
	p := &arr
	for &e in arr {
		e = p[0]
	}
}
`,
			{},
		},
		{
			"fill value through a pointer field",
			`package test

S :: struct {
	p: ^[3]int,
}

f :: proc() {
	arr: [3]int
	s := S{&arr}
	for &e in arr {
		e = s.p[0] * 2
	}
}
`,
			{},
		},
		{
			"type-switch binding",
			`package test

U :: union {
	[3]int,
	int,
}

f :: proc(u: U, x: int) -> bool {
	#partial switch v in u {
	case [3]int:
		for e in v {
			if e == x {
				return true
			}
		}
		return false
	}
	return false
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_use_stdlib = true})
}

// Copying a pointer or reading a field through one reads no element of the filled array.
@(test)
modernize_fill_takes_pointer_values :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

Config :: struct {
	fill: int,
}

f :: proc(ptrs: []^int, default_ptr: ^int) {
	for &e in ptrs {
		e = default_ptr
	}
}

g :: proc(xs: []int, cfg: ^Config) {
	for &e in xs {
		e = cfg.fill
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

Config :: struct {
	fill: int,
}

f :: proc(ptrs: []^int, default_ptr: ^int) {
	slice.fill(ptrs, default_ptr)
}

g :: proc(xs: []int, cfg: ^Config) {
	slice.fill(xs, cfg.fill)
}
`,
	)
}

// The call would reach the declaration that shadows the builtin, here the procedure itself.
@(test)
lint_use_stdlib_shadowed_builtin :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"procedure named max",
			`package test

max :: proc(a, b: int) -> int {
	if a > b {
		return a
	}
	return b
}
`,
			{},
		},
		{
			"local named max",
			`package test

f :: proc(a, b: int) -> int {
	max := 0
	_ = max
	if a > b {
		return a
	}
	return b
}
`,
			{},
		},
		{
			"range value by reference named max",
			`package test

f :: proc(a, b: int, xs: []int) -> int {
	for &max in xs {
		_ = max
	}
	if a > b {
		return a
	}
	return b
}
`,
			{},
		},
		{
			"unrolled range value named max",
			`package test

f :: proc(a, b: int) -> int {
	#unroll for max in 0 ..< 2 {
		_ = max
	}
	if a > b {
		return a
	}
	return b
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_use_stdlib = true})
}

// A package-level `max` in another file would capture the builtin call.
@(test)
lint_use_stdlib_builtin_declared_in_other_file :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

f :: proc(a, b: int) -> int {
	if a > b {
		return a
	}
	return b
}
`,
		files = {{"other.odin", "package test\nmax :: proc(a, b: int) -> int { return a }"}},
		config = {enable_lint_use_stdlib = true},
	}

	test.expect_lint_diagnostics(t, &src, {})
}

// The rewrite reads the value once, so a value that reads an element through a pointer to the
// element type, or calls a procedure that may read a package-level array, keeps the loop.
@(test)
lint_use_stdlib_fill_skips_pointer_field_and_call :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"field read through a pointer to an element",
			`package test

Item :: struct {
	x: int,
}

f :: proc() {
	items: [4]Item
	p := &items[0]
	for &e in items {
		e = Item{x = p.x * 2}
	}
}
`,
			{},
		},
		{
			"call that reads a package-level array",
			`package test

items: [4]int

next :: proc() -> int {
	return items[0] + 1
}

f :: proc() {
	for &e in items {
		e = next()
	}
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_use_stdlib = true})
}
