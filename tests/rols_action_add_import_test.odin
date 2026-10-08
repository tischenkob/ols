#+feature dynamic-literals

package tests

import "core:testing"

import test "src:testing"

@(test)
action_add_import_offers_nested_package :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "mem/virtual", source = `package virtual
		arena_init :: proc() {}
	`})

	source := test.Source {
		main = `package main

main :: proc() {
	virtual.arena_i{*}nit()
}
`,
		packages = packages[:],
		collections = {"core" = "test"},
	}

	test.expect_action(t, &source, {`import package "core:mem/virtual"`})
}
