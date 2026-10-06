package tests

import "core:odin/ast"
import "core:slice"
import "core:testing"

import "src:common"
import "src:server"
import test "src:testing"

// The names inactive_when_decls reports for the document of src, sorted.
@(private = "file")
inactive_names :: proc(src: ^test.Source) -> []string {
	context.allocator = context.temp_allocator
	names := make([dynamic]string, context.temp_allocator)
	for decl in server.inactive_when_decls(&src.document.ast) {
		for name in decl.names {
			append(&names, name.derived.(^ast.Ident).name)
		}
	}
	slice.sort(names[:])
	return names[:]
}

@(test)
when_inactive_known_and_unknown_conditions :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

IS_JS :: ODIN_OS == .JS

when ODIN_OS == .JS {
	js_a :: 1
} else when ODIN_DEBUG {
	debug_b :: 2
} else {
	rest_c :: 3
}

when IS_JS {
	js_d :: 4
	when ODIN_TEST {
		nested_e :: 5
	}
} else when ODIN_DEBUG {
	after_f :: 6
}

when ODIN_TEST {
	test_g :: 7
} else {
	else_h :: 8
}

when #config(NO_SUCH_DEFINE, true) {
	config_i :: 9
} else {
	config_j :: 10
}

main :: proc() {}{*}
`,
	}

	test.with_document(
		t,
		&source,
		proc(t: ^testing.T, src: ^test.Source, range: common.Range) {
			// The host is never js. An unknown condition keeps its branch and the ones after it, but a known
			// branch before it is still inactive, and a known active branch rules out the ones after it.
			expected := []string{"config_j", "js_a", "js_d", "nested_e"}
			got := inactive_names(src)
			testing.expectf(t, slice.equal(got, expected), "got %v, expected %v", got, expected)
		},
	)
}
