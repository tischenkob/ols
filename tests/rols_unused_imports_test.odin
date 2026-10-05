#+feature dynamic-literals

package tests

import "core:testing"

import test "src:testing"

// An import is used only where its name appears in the file, never because a value of one of its types flows through.
@(private = "file")
a_and_b_packages :: proc() -> []test.Package {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "a", source = "package a\n\nFoo :: struct {\n\tx: int,\n}\n"})
	append(
		&packages,
		test.Package{pkg = "b", source = "package b\n\nimport \"a\"\n\nget :: proc() -> a.Foo {\n\treturn {}\n}\n"},
	)
	return packages[:]
}

@(test)
import_reached_only_through_a_type_is_unused :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "a"
import "b"

use :: proc() -> int {
	f := b.get()
	return f.x
}
`,
		packages = a_and_b_packages(),
	}
	test.expect_unused_imports(t, &source, {"a"})
}

@(test)
aliased_import_reached_only_through_a_type_is_unused :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import mix "a"
import "b"

use :: proc() -> int {
	using f := b.get()
	return x
}
`,
		packages = a_and_b_packages(),
	}
	test.expect_unused_imports(t, &source, {"mix"})
}

@(test)
import_named_only_in_type_expressions_is_used :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import mix "a"
import "b"

S :: struct {
	using foo: mix.Foo,
}

use :: proc(s: S) -> int {
	when ODIN_OS == .Windows {
		_ = b.get
	}
	return s.x
}
`,
		packages = a_and_b_packages(),
	}
	test.expect_unused_imports(t, &source, {})
}

@(test)
blank_import_is_never_unused :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import _ "a"
`,
		packages = a_and_b_packages(),
	}
	test.expect_unused_imports(t, &source, {})
}

@(test)
import_named_only_in_a_union_where_clause_is_used :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "a"

U :: union($T: typeid) where size_of(T) > size_of(a.Foo) {
	T,
}
`,
		packages = a_and_b_packages(),
	}
	test.expect_unused_imports(t, &source, {})
}

@(test)
import_named_only_in_a_foreign_import_path_is_used :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "paths", source = "package paths\n\nLIB :: \"libfoo.a\"\n"})
	source := test.Source {
		main     = `package test

import "paths"

foreign import foo { paths.LIB }
`,
		packages = packages[:],
	}
	test.expect_unused_imports(t, &source, {})
}

@(test)
required_import_is_never_unused :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

@(require) import "a"
`,
		packages = a_and_b_packages(),
	}
	test.expect_unused_imports(t, &source, {})
}
