package tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

import test "src:testing"

// A whole-file resolve rebuilt the member table of an enum for every use of a member, and each
// build rescanned every comment of the file. A documented enum of this size took 99 s.
@(test)
rols_lint_large_documented_enum :: proc(t: ^testing.T) {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "package test\n\n@(deprecated=\"use g\")\nf :: proc() {}\n\nBig :: enum u32 {\n")
	for i in 0 ..< 3000 {
		fmt.sbprintf(&b, "\t// Doc of member %d.\n\tM%d = %d,\n", i, i, i)
	}
	strings.write_string(&b, "}\n\nmain :: proc() {\n\tf()\n}\n")

	src := test.Source {
		main = strings.to_string(b),
		config = {enable_lint_deprecated = true},
	}

	start := time.tick_now()
	test.expect_lint_diagnostics(t, &src, {{6009, "deprecated"}})
	elapsed := time.tick_since(start)

	testing.expectf(t, elapsed < 8 * time.Second, "a 3000 member enum took %v to lint", elapsed)
}
