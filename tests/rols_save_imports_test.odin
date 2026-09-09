#+feature dynamic-literals
package tests

import "core:testing"

import test "src:testing"

@(private = "file")
save_imports_packages :: proc() -> []test.Package {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package{pkg = "fmt", source = `package fmt
println :: proc(args: ..any) {}
`})

	append(
		&packages,
		test.Package {
			pkg = "strings",
			source = `package strings
trim_space :: proc(s: string) -> string { return s }
`,
		},
	)

	return packages[:]
}

@(test)
save_imports_adds_single_candidate_and_removes_unused :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

import "core:fmt"

main :: proc() {
	_ = strings.trim_space(" world ")
}
`,
		packages = save_imports_packages(),
		collections = {"core" = "test"},
	}

	test.expect_save_imports_applied(
		t,
		&source,
		`package main

import "core:strings"

main :: proc() {
	_ = strings.trim_space(" world ")
}
`,
	)
}

@(test)
save_imports_skips_ambiguous_candidate :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

import "core:fmt"

main :: proc() {
	_ = strings.trim_space(" world ")
}
`,
		packages = save_imports_packages(),
		collections = {"core" = "test", "vendor" = "test"},
	}

	test.expect_save_imports_applied(
		t,
		&source,
		`package main


main :: proc() {
	_ = strings.trim_space(" world ")
}
`,
	)
}
