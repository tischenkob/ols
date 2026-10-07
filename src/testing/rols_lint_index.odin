package ols_testing

import "core:testing"

import "src:server"

// rols: lints the main file, then expects the index entry name of the package directory pkg to carry `.Fallback`
// or not. A package that the lint's `when` evaluation builds into the index must be collected for the host.
expect_index_fallback_after_lint :: proc(t: ^testing.T, src: ^Source, pkg, name: string, fallback: bool) {
	setup(src)
	defer teardown(src)

	server.lint_document(src.document, &src.config, package_files(src))
	symbol, found := server.lookup(name, pkg, "")
	if !testing.expectf(t, found, "\n%s is not in the index of %s", name, pkg) do return
	testing.expectf(
		t,
		(.Fallback in symbol.flags) == fallback,
		"\nExpected %s.%s to be a fallback: %v, but its flags are %v",
		pkg,
		name,
		fallback,
		symbol.flags,
	)
}
