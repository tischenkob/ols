package tests

import "core:testing"

import test "src:testing"

LOOP_LABEL_ACTION :: "Add loop label"

@(test)
action_loop_label :: proc(t: ^testing.T) {
	range_loop := test.Source {
		main = `package test

main :: proc() {
	xs := []int{1, 2}
	{*}for x in xs {
		foo(x)
	}
}
`,
		config = {enable_code_action_loop_label = true},
	}

	test.expect_action_applied(
		t,
		&range_loop,
		LOOP_LABEL_ACTION,
		`package test

main :: proc() {
	xs := []int{1, 2}
	loop: for x in xs {
		foo(x)
	}
}
`,
	)

	nested := test.Source {
		main = `package test

main :: proc() {
	for i := 0; i < 10; i{*} += 1 {
		for j := 0; j < 10; j += 1 {
			break
		}
	}
}
`,
		config = {enable_code_action_loop_label = true},
	}

	test.expect_action_applied(
		t,
		&nested,
		LOOP_LABEL_ACTION,
		`package test

main :: proc() {
	outer: for i := 0; i < 10; i += 1 {
		for j := 0; j < 10; j += 1 {
			break
		}
	}
}
`,
	)

	already_labeled := test.Source {
		main = `package test

main :: proc() {
	outer: {*}for i := 0; i < 10; i += 1 {
		foo(i)
	}
}
`,
		config = {enable_code_action_loop_label = true},
	}

	test.expect_action_missing(t, &already_labeled, LOOP_LABEL_ACTION)

	in_body := test.Source {
		main = `package test

main :: proc() {
	for i := 0; i < 10; i += 1 {
		{*}foo(i)
	}
}
`,
		config = {enable_code_action_loop_label = true},
	}

	test.expect_action_missing(t, &in_body, LOOP_LABEL_ACTION)
}
