#+feature dynamic-literals
package tests

import "core:testing"

import "src:server"
import test "src:testing"

// Each expect consumes the cursor of its source, so every check builds a fresh one.
@(private = "file")
postfix_source :: proc(main: string, core := false) -> test.Source {
	source := test.Source {
		main = main,
		config = {enable_postfix_completions = true},
	}
	if core {
		source.collections = {
			"core" = "test",
		}
	}
	return source
}

@(private = "file")
expect_postfix :: proc(t: ^testing.T, main, label, text: string, core := false) {
	source := postfix_source(main, core)
	test.expect_completion_edit_text(t, &source, ".", label, text)
}

@(test)
postfix_bool_if_and_not :: proc(t: ^testing.T) {
	main := `package test
		main :: proc() {
			ok: bool
			ok.{*}
		}
		`
	expect_postfix(t, main, "if", "if ok {\n\t$0\n}")
	expect_postfix(t, main, "ifnot", "if !ok {\n\t$0\n}")
	expect_postfix(t, main, "not", "!ok")
}

@(test)
postfix_struct_field_bool :: proc(t: ^testing.T) {
	main := `package test
		Foo :: struct {
			flag: bool,
		}
		main :: proc() {
			foo: Foo
			foo.flag.{*}
		}
		`
	expect_postfix(t, main, "if", "if foo.flag {\n\t$0\n}")
}

@(test)
postfix_int_for :: proc(t: ^testing.T) {
	main := `package test
		main :: proc() {
			n: int
			n.{*}
		}
		`
	expect_postfix(t, main, "for", "for ${1:i} in 0..<n {\n\t$0\n}")
}

@(test)
postfix_enum_switch_lists_every_case :: proc(t: ^testing.T) {
	main := `package test
		Color :: enum {
			Red,
			Green,
		}
		main :: proc() {
			c: Color
			c.{*}
		}
		`
	expect_postfix(t, main, "switch", "switch c {\ncase .Red:\n\t$0\ncase .Green:\n}")
}

@(test)
postfix_enum_type_name_has_no_templates :: proc(t: ^testing.T) {
	source := postfix_source(
		`package test
		Color :: enum {
			Red,
			Green,
		}
		main :: proc() {
			Color.{*}
		}
		`,
	)
	test.expect_completion_labels(t, &source, ".", {"Red"}, {"switch", "&", "return", "print"})
}

@(test)
postfix_call_or_return_and_defer :: proc(t: ^testing.T) {
	main := `package test
		get :: proc() -> (int, bool) {
			return 1, true
		}
		f :: proc() -> bool {
			get().{*}
		}
		`
	expect_postfix(t, main, "orr", "get() or_return")
	expect_postfix(t, main, "ore", "get() or_else $0")
	expect_postfix(t, main, "defer", "defer get()")

	source := postfix_source(main)
	test.expect_completion_labels(t, &source, ".", {"orr"}, {"nil", "notnil"})
}

@(test)
postfix_variable_has_no_call_templates :: proc(t: ^testing.T) {
	source := postfix_source(`package test
		main :: proc() {
			n: int
			n.{*}
		}
		`)
	test.expect_completion_labels(t, &source, ".", {"&", "var", "cast"}, {"orr", "ore", "defer", "^", "return"})
}

@(test)
postfix_pointer_deref_and_free :: proc(t: ^testing.T) {
	main := `package test
		main :: proc() {
			p: ^int
			p.{*}
		}
		`
	expect_postfix(t, main, "^", "p^")
	expect_postfix(t, main, "&", "&p")
	expect_postfix(t, main, "free", "free(p)")
	expect_postfix(t, main, "nil", "if p == nil {\n\t$0\n}")
}

@(test)
postfix_statement_templates_need_line_start :: proc(t: ^testing.T) {
	source := postfix_source(`package test
		main :: proc() {
			ok: bool
			y := ok.{*}
		}
		`)
	test.expect_completion_labels(t, &source, ".", {"not", "&", "cast"}, {"if", "ifnot", "var", "return", "print"})
}

@(test)
postfix_log_adds_import :: proc(t: ^testing.T) {
	source := postfix_source(`package test

		main :: proc() {
			n: int
			n.{*}
		}
		`, core = true)
	test.expect_completion_edits(
		t,
		&source,
		".",
		"logd",
		server.TextEdit {
			newText = "log.debugf(\"$1%v\", n)",
			range = {start = {line = 4, character = 5}, end = {line = 4, character = 5}},
		},
		{
			{range = {start = {line = 4, character = 3}, end = {line = 4, character = 5}}},
			{newText = "import \"core:log\"\n", range = {start = {line = 2}, end = {line = 2}}},
		},
	)
}

@(test)
postfix_print_reuses_import_alias :: proc(t: ^testing.T) {
	source := postfix_source(
		`package test
		import f "core:fmt"
		main :: proc() {
			n: int
			n.{*}
		}
		`,
		core = true,
	)
	test.expect_completion_edits(
		t,
		&source,
		".",
		"print",
		server.TextEdit {
			newText = "f.println(n)",
			range = {start = {line = 4, character = 5}, end = {line = 4, character = 5}},
		},
		{{range = {start = {line = 4, character = 3}, end = {line = 4, character = 5}}}},
	)
}

@(test)
postfix_string_pseudo_methods :: proc(t: ^testing.T) {
	main := `package test
		main :: proc() {
			s: string
			s.{*}
		}
		`
	expect_postfix(t, main, "contains", "strings.contains(s, $0)", core = true)
	expect_postfix(t, main, "parse_int", "strconv.parse_int(s)", core = true)
	expect_postfix(t, main, "delete", "delete(s)", core = true)
}

@(test)
postfix_dynamic_array_pseudo_methods :: proc(t: ^testing.T) {
	main := `package test
		main :: proc() {
			xs: [dynamic]string
			xs.{*}
		}
		`
	expect_postfix(t, main, "sort", "slice.sort(xs[:])", core = true)
	expect_postfix(t, main, "join", "strings.join(xs[:], $0)", core = true)
	expect_postfix(t, main, "delete", "delete(xs)", core = true)
}

@(test)
postfix_map_pseudo_methods :: proc(t: ^testing.T) {
	main := `package test
		main :: proc() {
			m: map[string]int
			m.{*}
		}
		`
	expect_postfix(t, main, "delete", "delete(m)", core = true)
	expect_postfix(t, main, "map_keys", "slice.map_keys(m)", core = true)
	expect_postfix(t, main, "fori", "for ${1:k}, ${2:v} in m {\n\t$0\n}", core = true)
}

@(test)
postfix_slice_keeps_upstream_for :: proc(t: ^testing.T) {
	main := `package test
		main :: proc() {
			xs: []int
			xs.{*}
		}
		`
	expect_postfix(t, main, "for", "for i in xs {\n\t$0 \n}")

	source := postfix_source(main)
	test.expect_completion_label_order(t, &source, ".", {"len", "for", "fori"})
}

@(test)
postfix_flag_off :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		main :: proc() {
			ok: bool
			ok.{*}
		}
		`,
	}
	test.expect_completion_labels(t, &source, ".", {}, {"if", "not", "&", "return"})
}

@(test)
postfix_partial_label_is_replaced :: proc(t: ^testing.T) {
	source := postfix_source(`package test
		main :: proc() {
			ok: bool
			ok.no{*}
		}
		`)
	test.expect_completion_edits(
		t,
		&source,
		"",
		"not",
		server.TextEdit{newText = "!ok", range = {start = {line = 3, character = 6}, end = {line = 3, character = 8}}},
		{{range = {start = {line = 3, character = 3}, end = {line = 3, character = 6}}}},
	)
}

@(test)
postfix_receiver_text_is_escaped :: proc(t: ^testing.T) {
	main := `package test
		get :: proc(s: string) -> int {
			return 0
		}
		main :: proc() {
			get("a$}").{*}
		}
		`
	expect_postfix(t, main, "paren", "(get(\"a\\$\\}\"))")
}

@(test)
postfix_single_variant_union_or_else :: proc(t: ^testing.T) {
	main := `package test
		Opt :: union {
			int,
		}
		main :: proc() {
			m: Opt
			m.{*}
		}
		`
	expect_postfix(t, main, "ore", "m.? or_else $0")
}

@(test)
postfix_union_of_two_has_no_or_else :: proc(t: ^testing.T) {
	source := postfix_source(
		`package test
		U :: union {
			int,
			f32,
		}
		main :: proc() {
			u: U
			u.{*}
		}
		`,
	)
	test.expect_completion_labels(t, &source, ".", {"switch", "nil"}, {"ore"})
}

@(test)
postfix_map_index_in_package_or_else :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "cfg", source = `package cfg
		Kind :: enum {
			A,
		}
		`})
	source := postfix_source(
		`package test
		import "cfg"
		m: map[string]cfg.Kind
		main :: proc() {
			m["k"].{*}
		}
		`,
	)
	source.packages = packages[:]
	test.expect_completion_edit_text(t, &source, ".", "ore", "m[\"k\"] or_else $0")
}

@(test)
postfix_conversion_has_no_call_templates :: proc(t: ^testing.T) {
	source := postfix_source(`package test
		main :: proc() {
			n: int
			f32(n).{*}
		}
		`)
	test.expect_completion_labels(t, &source, ".", {"paren", "cast"}, {"orr", "ore", "defer", "&"})
}

@(private = "file")
expect_postfix_labels :: proc(t: ^testing.T, main: string, present, absent: []string) {
	source := postfix_source(main, core = true)
	test.expect_completion_labels(t, &source, ".", present, absent)
}

@(private = "file")
GET_INT_BOOL :: `package test
		get :: proc() -> (int, bool) {
			return 1, true
		}
		`

@(test)
postfix_or_return_needs_a_compatible_procedure :: proc(t: ^testing.T) {
	expect_postfix_labels(t, GET_INT_BOOL + `f :: proc() -> bool {
			get().{*}
		}
		`, {"orr", "ore"}, {})
	expect_postfix_labels(t, GET_INT_BOOL + `f :: proc() {
			get().{*}
		}
		`, {"ore"}, {"orr"})
	expect_postfix_labels(t, GET_INT_BOOL + `f :: proc() -> (int, bool) {
			get().{*}
		}
		`, {"ore"}, {"orr"})
	expect_postfix_labels(t, GET_INT_BOOL + `f :: proc() -> (n: int, ok: b32) {
			get().{*}
		}
		`, {"orr"}, {})
	expect_postfix_labels(
		t,
		GET_INT_BOOL + `E :: union {
			int,
		}
		f :: proc() -> E {
			get().{*}
		}
		`,
		{"ore"},
		{"orr"},
	)
}

@(test)
postfix_or_return_error_into_union :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		Alloc_Error :: enum {
			None,
			Out_Of_Memory,
		}
		Error :: union {
			Alloc_Error,
		}
		get :: proc() -> (int, Alloc_Error) {
			return 1, .None
		}
		f :: proc() -> Error {
			get().{*}
		}
		`,
		{"orr", "ore"},
		{},
	)
}

@(test)
postfix_call_with_non_error_last_result :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		get :: proc() -> (int, int) {
			return 1, 2
		}
		f :: proc() -> int {
			get().{*}
		}
		`,
		{"defer", "print"},
		{"orr", "ore", "var", "printf", "logd", "return"},
	)
}

@(test)
postfix_or_else_needs_two_results :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		get :: proc() -> (int, int, bool) {
			return 1, 2, true
		}
		f :: proc() {
			get().{*}
		}
		`,
		{"defer"},
		{"ore"},
	)
}

@(test)
postfix_require_results_has_no_defer :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		@(require_results)
		get :: proc() -> (int, bool) {
			return 1, true
		}
		f :: proc() {
			get().{*}
		}
		`,
		{"ore"},
		{"defer"},
	)
}

@(test)
postfix_group_call_has_no_call_templates :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		get_int :: proc(n: int) -> int {
			return n
		}
		get_f32 :: proc(n: f32) -> f32 {
			return n
		}
		get :: proc {
			get_int,
			get_f32,
		}
		f :: proc() {
			get(1).{*}
		}
		`,
		{"var", "print"},
		{"defer", "orr", "ore"},
	)
}

@(test)
postfix_address_needs_an_addressable_value :: proc(t: ^testing.T) {
	expect_postfix_labels(t, `package test
		f :: proc(n: int) {
			n.{*}
		}
		`, {"var"}, {"&"})
	expect_postfix_labels(
		t,
		`package test
		f :: proc(xs: []int) {
			for x in xs {
				x.{*}
			}
		}
		`,
		{"var"},
		{"&"},
	)
	expect_postfix_labels(
		t,
		`package test
		f :: proc(xs: []int) {
			for &x in xs {
				x.{*}
			}
		}
		`,
		{"&"},
		{},
	)
	expect_postfix_labels(
		t,
		`package test
		S :: struct {
			a: int,
		}
		f :: proc(s: S) {
			s.a.{*}
		}
		`,
		{"var"},
		{"&"},
	)
	expect_postfix_labels(
		t,
		`package test
		S :: struct {
			a: int,
		}
		f :: proc(p: ^S) {
			p.a.{*}
		}
		`,
		{"&"},
		{},
	)
	expect_postfix_labels(t, `package test
		f :: proc(s: string) {
			s[0].{*}
		}
		`, {"var"}, {"&"})
	expect_postfix_labels(t, `package test
		G: int
		f :: proc() {
			G.{*}
		}
		`, {"&"}, {})
	expect_postfix_labels(t, `package test
		f :: proc(xs: []int) {
			xs[0].{*}
		}
		`, {"&"}, {})
}

@(test)
postfix_return_needs_a_matching_result :: proc(t: ^testing.T) {
	expect_postfix_labels(t, `package test
		f :: proc() -> int {
			n: int
			n.{*}
		}
		`, {"return"}, {})
	expect_postfix_labels(t, `package test
		f :: proc() -> f32 {
			n: int
			n.{*}
		}
		`, {"var"}, {"return"})
	expect_postfix_labels(
		t,
		`package test
		f :: proc() -> (int, bool) {
			n: int
			n.{*}
		}
		`,
		{"var"},
		{"return"},
	)
	expect_postfix_labels(
		t,
		`package test
		U :: union {
			int,
			f32,
		}
		f :: proc() -> U {
			n: int
			n.{*}
		}
		`,
		{"return"},
		{},
	)
}

@(test)
postfix_slice_helpers_follow_element_constraints :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		f :: proc() {
			xs: []bool
			xs.{*}
		}
		`,
		{"contains", "clone"},
		{"sort", "min", "is_sorted"},
	)
	expect_postfix_labels(
		t,
		`package test
		S :: struct {
			a: int,
		}
		f :: proc() {
			xs: []S
			xs.{*}
		}
		`,
		{"clone", "sort_by", "reverse"},
		{"sort", "contains", "linear_search", "min"},
	)
	expect_postfix_labels(
		t,
		`package test
		K :: enum {
			A,
		}
		f :: proc() {
			xs: []K
			xs.{*}
		}
		`,
		{"sort", "contains"},
		{},
	)
}

@(test)
postfix_fixed_array_needs_addressable_for_slicing :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		f :: proc(a: [4]int) {
			a.{*}
		}
		`,
		{"fori"},
		{"sort", "copy", "raw_data", "clone"},
	)
	expect_postfix_labels(
		t,
		`package test
		f :: proc() {
			a: [4]int
			a.{*}
		}
		`,
		{"sort", "copy", "raw_data"},
		{"delete"},
	)
}

@(test)
postfix_distinct_string_has_no_string_procedures :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		D :: distinct string
		f :: proc() {
			d: D
			d.{*}
		}
		`,
		{"fori"},
		{"contains", "delete", "parse_int"},
	)
	expect_postfix_labels(
		t,
		`package test
		D :: distinct []string
		f :: proc() {
			d: D
			d.{*}
		}
		`,
		{"sort"},
		{"join"},
	)
}

@(test)
postfix_no_nil_union_has_no_nil_check :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		U :: union #no_nil {
			int,
			f32,
		}
		f :: proc() {
			u: U
			u.{*}
		}
		`,
		{"switch"},
		{"nil", "notnil"},
	)
}

@(test)
postfix_pointer_to_slice_iterates_pointee :: proc(t: ^testing.T) {
	expect_postfix(
		t,
		`package test
		f :: proc() {
			p: ^[]int
			p.{*}
		}
		`,
		"fori",
		"for ${1:e}, ${2:i} in p^ {\n\t$0\n}",
	)
}

@(test)
postfix_grouped_results_are_several_values :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		get :: proc() -> (ok, done: bool) {
			return true, true
		}
		f :: proc() {
			get().{*}
		}
		`,
		{"ore", "print"},
		{"if", "not", "var", "paren"},
	)
}

@(test)
postfix_proc_type_conversion_is_one_value :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		Cb :: proc() -> int
		g :: proc() -> int {
			return 1
		}
		f :: proc() -> int {
			Cb(g).{*}
		}
		`,
		{"nil", "var"},
		{"defer", "orr", "for", "return"},
	)
}

@(test)
postfix_enum_switch_skips_aliases :: proc(t: ^testing.T) {
	expect_postfix(
		t,
		`package test
		E :: enum {
			A,
			B,
			Last = B,
		}
		f :: proc() {
			e: E
			e.{*}
		}
		`,
		"switch",
		"switch e {\ncase .A:\n\t$0\ncase .B:\n}",
	)
}

@(test)
postfix_untyped_variable_returns_its_default_type :: proc(t: ^testing.T) {
	expect_postfix_labels(t, `package test
		f :: proc() -> i8 {
			n := 5
			n.{*}
		}
		`, {"var"}, {"return"})
	expect_postfix_labels(t, `package test
		f :: proc() -> int {
			n := 5
			n.{*}
		}
		`, {"return"}, {})
}

@(test)
postfix_contextless_has_no_context_procedures :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		f :: proc "contextless" () {
			s: string
			s.{*}
		}
		`,
		{"raw_data", "var"},
		{"print", "logd", "contains", "delete"},
	)
}

@(test)
postfix_bit_field_field_has_no_address :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		B :: bit_field u8 {
			x: u8 | 4,
		}
		f :: proc() {
			b: B
			b.x.{*}
		}
		`,
		{"var"},
		{"&"},
	)
}

@(test)
postfix_import_name_clash :: proc(t: ^testing.T) {
	expect_postfix_labels(t, `package test
		f :: proc() {
			log := 1
			n: int
			n.{*}
		}
		`, {"print"}, {"logd"})
}

@(test)
postfix_builtin_call_has_no_defer :: proc(t: ^testing.T) {
	expect_postfix_labels(t, `package test
		f :: proc() {
			xs: []int
			len(xs).{*}
		}
		`, {"var"}, {"defer"})
}

@(test)
postfix_single_value_or_return_is_a_statement :: proc(t: ^testing.T) {
	main :: `package test
		E :: union {
			int,
		}
		step :: proc() -> E {
			return nil
		}
		`
	expect_postfix_labels(t, main + `run :: proc() -> E {
			step().{*}
		}
		`, {"orr"}, {})
	expect_postfix_labels(t, main + `run :: proc() -> E {
			x := step().{*}
		}
		`, {"paren"}, {"orr"})
}

@(test)
postfix_distinct_types_are_not_the_same :: proc(t: ^testing.T) {
	main :: `package test
		A :: distinct u32
		B :: distinct u32
		`
	expect_postfix_labels(t, main + `f :: proc() -> A {
			b: B
			b.{*}
		}
		`, {"var"}, {"return"})
	expect_postfix_labels(t, main + `f :: proc() -> A {
			a: A
			a.{*}
		}
		`, {"return"}, {})
}

@(test)
postfix_package_declaration_hides_import :: proc(t: ^testing.T) {
	source := postfix_source(`package test
		f :: proc() {
			n: int
			n.{*}
		}
		`, core = true)
	source.files = {{"b.odin", `package test
log :: proc(msg: string) {}
`}}
	test.expect_completion_labels(t, &source, ".", {"print"}, {"logd"})
}

@(test)
postfix_local_hides_import_alias :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		import "core:slice"
		f :: proc() {
			xs: []int
			slice := xs[:1]
			xs.{*}
		}
		`,
		{"copy"},
		{"sort", "clone"},
	)
}

@(test)
postfix_defer_has_no_return :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		get :: proc() -> (int, bool) {
			return 1, true
		}
		f :: proc() -> bool {
			n: bool
			defer {
				get().{*}
			}
			return n
		}
		`,
		{"ore"},
		{"orr"},
	)
	expect_postfix_labels(
		t,
		`package test
		f :: proc() -> int {
			n: int
			defer {
				n.{*}
			}
			return 0
		}
		`,
		{"var"},
		{"return"},
	)
}

@(test)
postfix_arrow_call_with_several_results :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		T :: struct {
			f: proc(self: ^T) -> (int, bool),
		}
		g :: proc() {
			x: ^T
			x->f().{*}
		}
		`,
		{"print"},
		{"var", "nil", "printf", "logd", "paren"},
	)
}

@(test)
postfix_poly_union_instantiation_is_a_type :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		Opt :: union($T: typeid) {
			T,
		}
		f :: proc() {
			Opt(int).{*}
		}
		`,
		{"switch"},
		{"var", "nil", "print", "paren"},
	)
}

@(test)
postfix_continued_line_is_not_a_statement :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		show :: proc(a: string, b: bool) {}
		f :: proc() {
			ok: bool
			show(
				"x",
				ok.{*}
			)
		}
		`,
		{"not", "paren"},
		{"if", "ifnot", "var", "print", "return"},
	)
	expect_postfix_labels(
		t,
		`package test
		f :: proc() {
			a, ok: bool
			if a &&
			   ok.{*} {
			}
		}
		`,
		{"not"},
		{"if", "var", "print"},
	)
}

@(test)
postfix_reverse_loop_value_has_no_address :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		f :: proc(xs: []int) {
			#reverse for x in xs {
				x.{*}
			}
		}
		`,
		{"var"},
		{"&"},
	)
}

@(test)
postfix_parenthesized_call_is_a_call :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		get :: proc() -> int {
			return 1
		}
		f :: proc() {
			(get()).{*}
		}
		`,
		{"for", "var"},
		{"nil", "&"},
	)
}

@(test)
postfix_map_index_is_addressable_only_whole :: proc(t: ^testing.T) {
	main :: `package test
		Player :: struct {
			score: int,
		}
		`
	expect_postfix_labels(
		t,
		main + `f :: proc() {
			players: map[string]Player
			players["bob"].{*}
		}
		`,
		{"&"},
		{},
	)
	expect_postfix_labels(
		t,
		main + `f :: proc() {
			players: map[string]Player
			players["bob"].score.{*}
		}
		`,
		{"var"},
		{"&"},
	)
	expect_postfix_labels(
		t,
		`package test
		f :: proc() {
			m: map[string][4]int
			m["a"].{*}
		}
		`,
		{"fori", "&"},
		{"sort", "copy", "raw_data", "clone"},
	)
	expect_postfix_labels(
		t,
		`package test
		f :: proc() {
			m: map[string][4]int
			m["a"][0].{*}
		}
		`,
		{"var"},
		{"&"},
	)
}

@(test)
postfix_deferred_statement_has_no_declaration :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		get :: proc() -> int {
			return 1
		}
		f :: proc() {
			n: int
			defer get().{*}
		}
		`,
		{"print"},
		{"var", "defer"},
	)
}

@(test)
postfix_map_index_through_pointer :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		Player :: struct {
			score: int,
		}
		f :: proc(players: ^map[string]Player) {
			players["bob"].score.{*}
		}
		`,
		{"var"},
		{"&"},
	)
	expect_postfix_labels(
		t,
		`package test
		f :: proc(pm: ^map[string][4]int) {
			pm["a"].{*}
		}
		`,
		{"fori"},
		{"sort", "copy"},
	)
}

@(test)
postfix_string_byte_through_pointer :: proc(t: ^testing.T) {
	expect_postfix_labels(t, `package test
		f :: proc(ps: ^string) {
			ps[0].{*}
		}
		`, {"var"}, {"&"})
}

@(test)
postfix_wrapped_loop_header_value :: proc(t: ^testing.T) {
	expect_postfix_labels(
		t,
		`package test
		f :: proc(xs: []int) {
			for x in
			    xs {
				x.{*}
			}
		}
		`,
		{"var"},
		{"&"},
	)
}
