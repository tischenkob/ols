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

@(private = "file")
loop_source :: proc(main: string) -> test.Source {
	return test.Source{main = main, config = {enable_code_action_loop_label = true}}
}

@(test)
action_loop_label_forms :: proc(t: ^testing.T) {
	conditional := loop_source(`package test

main :: proc() {
	c := true
	{*}for c {
		foo()
	}
}
`)

	test.expect_action_applied(t, &conditional, LOOP_LABEL_ACTION, `package test

main :: proc() {
	c := true
	loop: for c {
		foo()
	}
}
`)

	infinite := loop_source(`package test

main :: proc() {
	{*}for {
		break
	}
}
`)

	test.expect_action_applied(t, &infinite, LOOP_LABEL_ACTION, `package test

main :: proc() {
	loop: for {
		break
	}
}
`)

	do_body := loop_source(`package test

main :: proc() {
	{*}for i := 0; i < 3; i += 1 do foo(i)
}
`)

	test.expect_action_applied(t, &do_body, LOOP_LABEL_ACTION, `package test

main :: proc() {
	loop: for i := 0; i < 3; i += 1 do foo(i)
}
`)

	// The inner loop of a nest holds no loop of its own, so it is a plain `loop`.
	inner := loop_source(`package test

main :: proc() {
	for i := 0; i < 10; i += 1 {
		{*}for j := 0; j < 10; j += 1 {
			foo(j)
		}
	}
}
`)

	test.expect_action_applied(t, &inner, LOOP_LABEL_ACTION, `package test

main :: proc() {
	for i := 0; i < 10; i += 1 {
		loop: for j := 0; j < 10; j += 1 {
			foo(j)
		}
	}
}
`)

	not_a_loop := loop_source(`package test

main :: proc() {
	x := 1
	{*}switch x {
	case 1:
		foo()
	}
}
`)

	test.expect_action_missing(t, &not_a_loop, LOOP_LABEL_ACTION)
}
