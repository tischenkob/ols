package tests

import "core:testing"

import test "src:testing"

TO_DO_ACTION :: "Convert to do"
TO_BLOCK_ACTION :: "Convert to block"

expect_do_block :: proc(t: ^testing.T, action, main, expected: string) {
	source := test.Source{main = main, config = {enable_code_action_do_block = true}}
	test.expect_action_applied(t, &source, action, expected)
}

expect_no_do_block :: proc(t: ^testing.T, main: string) {
	source := test.Source{main = main, config = {enable_code_action_do_block = true}}
	test.expect_action_missing(t, &source, TO_DO_ACTION)
}

@(test)
do_block_to_do :: proc(t: ^testing.T) {
	expect_do_block(t, TO_DO_ACTION, `package test

main :: proc() {
	if {*}x > 0 {
		foo()
	}
}
`, `package test

main :: proc() {
	if x > 0 do foo()
}
`)
	expect_do_block(t, TO_DO_ACTION, `package test

main :: proc() {
	for {*}i in 0 ..< 3 {
		foo(i)
	}
}
`, `package test

main :: proc() {
	for i in 0 ..< 3 do foo(i)
}
`)
	expect_do_block(t, TO_DO_ACTION, `package test

main :: proc() {
	for {
		if {*}x > 0 {
			continue
		}
	}
}
`, `package test

main :: proc() {
	for {
		if x > 0 do continue
	}
}
`)
	expect_do_block(t, TO_DO_ACTION, `package test

main :: proc() {
	when {*}ODIN_OS == .Darwin {
		foo()
	}
}
`, `package test

main :: proc() {
	when ODIN_OS == .Darwin do foo()
}
`)
	expect_do_block(t, TO_DO_ACTION, `package test

main :: proc() {
	if {*}x > 0 {
		foo()
	} else {
		bar()
	}
}
`, `package test

main :: proc() {
	if x > 0 do foo()
	else do bar()
}
`)
}

@(test)
do_block_to_do_refused :: proc(t: ^testing.T) {
	// Two statements.
	expect_no_do_block(t, `package test

main :: proc() {
	if {*}x > 0 {
		foo()
		bar()
	}
}
`)
	// A comment inside.
	expect_no_do_block(t, `package test

main :: proc() {
	if {*}x > 0 {
		// why
		foo()
	}
}
`)
	// A nested if.
	expect_no_do_block(t, `package test

main :: proc() {
	if {*}x > 0 {
		if y {
			foo()
		}
	}
}
`)
	// A multi-line statement.
	expect_no_do_block(t, `package test

main :: proc() {
	if {*}x > 0 {
		foo(
			x,
		)
	}
}
`)
	// An else-if chain.
	expect_no_do_block(t, `package test

main :: proc() {
	if {*}x > 0 {
		foo()
	} else if y {
		bar()
	}
}
`)
}

@(test)
do_block_to_block :: proc(t: ^testing.T) {
	expect_do_block(t, TO_BLOCK_ACTION, `package test

main :: proc() {
	if {*}x > 0 do foo()
}
`, `package test

main :: proc() {
	if x > 0 {
		foo()
	}
}
`)
	expect_do_block(t, TO_BLOCK_ACTION, `package test

main :: proc() {
	if {*}x > 0 {
		foo()
	} else do bar()
}
`, `package test

main :: proc() {
	if x > 0 {
		foo()
	} else {
		bar()
	}
}
`)
	expect_do_block(t, TO_BLOCK_ACTION, `package test

main :: proc() {
    for {*}i in 0 ..< 3 do foo(i)
}
`, `package test

main :: proc() {
    for i in 0 ..< 3 {
        foo(i)
    }
}
`)
}

@(test)
do_block_round_trip :: proc(t: ^testing.T) {
	original, result := apply_twice(t, `package test

main :: proc() {
	if {*}x > 0 do foo()
	else do bar()
}
`, TO_BLOCK_ACTION, TO_DO_ACTION, {enable_code_action_do_block = true})
	testing.expectf(t, result == original, "\nExpected:\n%s\n\nGot:\n%s", original, result)
}

@(test)
do_block_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	if {*}x > 0 do foo()
}
`,
		config = {enable_code_action_do_block = false},
	}
	test.expect_action_missing(t, &source, TO_BLOCK_ACTION)
}
