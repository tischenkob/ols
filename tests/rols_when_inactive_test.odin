package tests

import "core:odin/ast"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
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

SIZE :: 64

when SIZE * 2 == 128 {
	arith_k :: 11
} else {
	arith_l :: 12
}

when 1.5 == 1.5 {
	float_m :: 13
} else {
	float_n :: 14
}

foreign {
	when ODIN_OS == .JS {
		foreign_o :: proc() ---
	}
}

main :: proc() {}{*}
`,
	}

	test.with_document(
		t,
		&source,
		proc(t: ^testing.T, src: ^test.Source, range: common.Range) {
			// The host is never js. Arithmetic and float literals do not fold, so those chains mark nothing. An unknown condition keeps its branch and the ones after it, but a known
			// branch before it is still inactive, and a known active branch rules out the ones after it.
			expected := []string{"config_j", "foreign_o", "js_a", "js_d", "nested_e"}
			got := inactive_names(src)
			testing.expectf(t, slice.equal(got, expected), "got %v, expected %v", got, expected)
		},
	)
}

// A comparison or `&&` that the evaluator cannot fold, such as an ordering of strings, `&&` of integers or an
// integer too large for an int, is unknown, in a condition and in a constant that a condition names. An integer
// ordering still folds.
@(test)
when_inactive_unfoldable_operands_are_unknown :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

LESS :: "a" < "b"
BOTH :: 1 && 2

when LESS {
	less_a :: 1
} else {
	less_b :: 2
}

when BOTH {
	both_c :: 3
} else {
	both_d :: 4
}

when "a" < "b" {
	lit_e :: 5
} else {
	lit_f :: 6
}

when 1 < 2 {
	int_g :: 7
} else {
	int_h :: 8
}

BIG :: 18446744073709551616

when BIG > 0 {
	big_i :: 9
} else {
	big_j :: 10
}

main :: proc() {}{*}
`,
	}

	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, range: common.Range) {
		expected := []string{"int_h"}
		got := inactive_names(src)
		testing.expectf(t, slice.equal(got, expected), "got %v, expected %v", got, expected)
	})
}

// With the package files, a condition reads the constants of a sibling file, also through a constant of its own
// file. Without them it is unknown and marks nothing. A sibling with another `package` clause does not count.
@(test)
when_inactive_reads_constants_of_sibling_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, dir_err := os.make_directory_temp("", "rols_when_*", context.temp_allocator)
	if !testing.expect_value(t, dir_err, nil) do return
	defer os.remove_all(dir)
	files := [][2]string {
		{
			"a.odin",
			"package p\n\nON :: !FLAG\n\nwhen FLAG {\n\ton_a :: 1\n} else {\n\toff_b :: 2\n}\n\nwhen ON {\n\ton_c :: 3\n} else {\n\toff_d :: 4\n}\n\nwhen OTHER {\n\tother_e :: 5\n}\n",
		},
		{"b.odin", "package p\n\nFLAG :: true\n"},
		{"c_test.odin", "package p_test\n\nOTHER :: false\n"},
	}
	paths := make([]string, len(files))
	for entry, i in files {
		paths[i] = strings.concatenate({dir, "/", entry[0]})
		if !testing.expect_value(t, os.write_entire_file(paths[i], entry[1]), nil) do return
	}
	parsed, ok := server.parse_syntax(paths[0], files[0][1])
	if !testing.expect(t, ok) do return

	names := proc(inactive: map[^ast.Value_Decl]struct{}) -> []string {
		names := make([dynamic]string)
		for decl in inactive do append(&names, decl.names[0].derived.(^ast.Ident).name)
		slice.sort(names[:])
		return names[:]
	}
	alone := names(server.inactive_when_decls(&parsed))
	testing.expectf(t, len(alone) == 0, "got %v without the package files", alone)
	pkg := server.When_Package {
		files     = paths,
		allocator = context.temp_allocator,
	}
	got := names(server.inactive_when_decls(&parsed, &pkg))
	testing.expectf(t, slice.equal(got, []string{"off_b", "on_c"}), "got %v, expected [off_b, on_c]", got)
}

// Only a selector that a `when` condition reaches, directly or through a constant, reads the imported package, so
// a constant such as `HANDLE :: win.HANDLE` costs no parse of its package.
@(test)
when_inactive_reads_only_the_packages_a_condition_reaches :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "package app\n\nimport cfg \"../cfg\"\nimport win \"../win\"\n\nHANDLE :: win.HANDLE\nON :: cfg.ON\n\nwhen ON {\n\ta :: 1\n}\n"
	parsed, ok := server.parse_syntax("/rols_no_such_dir/app/a.odin", text)
	if !testing.expect(t, ok) do return
	pkg := server.When_Package {
		allocator = context.temp_allocator,
	}
	server.inactive_when_decls(&parsed, &pkg)
	dirs := make([dynamic]string)
	for dir in pkg.imported do append(&dirs, filepath.base(dir))
	testing.expectf(t, slice.equal(dirs[:], []string{"cfg"}), "got %v", dirs)
}
