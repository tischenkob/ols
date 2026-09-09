package tests

import "core:testing"

import "src:server"
import test "src:testing"

@(test)
folding_ranges :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:fmt"
import "core:strings"

Point :: struct {
	x: int,
	y: int,
}

// first
// second
// third
main :: proc() {
	if true {
		fmt.println("a")
	}
	for i in 0 ..< 2 {
		fmt.println(i)
	}
	strings.join(
		{"a", "b"},
		", ",
	)
	switch 1 {
	case 1:
		fmt.println("one")
		fmt.println("uno")
	case 2:
		fmt.println("two")
		fmt.println("dos")
	}
}

empty :: proc() {}
`,
	}

	// 0-based lines: imports 2-3, struct 5-8, comment 10-12, main 13-32 with if 14-16,
	// for 17-19, call 20-23, switch 24-31, cases 25-27 and 28-30. A closing token alone
	// on its line stays visible, so those ranges end one line early.
	test.expect_folding_ranges(
		t,
		&source,
		{
			{2, 3, "imports"},
			{5, 7, "region"},
			{10, 12, "comment"},
			{13, 31, "region"},
			{14, 15, "region"},
			{17, 18, "region"},
			{20, 22, "region"},
			{24, 30, "region"},
			{25, 27, "region"},
			{28, 30, "region"},
		},
	)
}
