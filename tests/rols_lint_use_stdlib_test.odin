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
			"abs on an integer",
			`package test

main :: proc(x: int) -> int {
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
