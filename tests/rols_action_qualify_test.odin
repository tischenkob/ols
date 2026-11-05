#+feature dynamic-literals
package tests

import "core:strings"
import "core:testing"

import test "src:testing"

QUALIFY :: "Qualify enum member"
DROP_ENUM :: "Drop enum type"
ADD_LIT :: "Add literal type"
DROP_LIT :: "Drop literal type"

QUALIFY_PRELUDE :: `package test

Kind :: enum {
	A,
	B,
}

Other :: enum {
	A,
}

Set :: bit_set[Kind]

P :: struct {
	x, y: int,
}

Q :: struct {
	p:    P,
	k:    Kind,
	list: []P,
	anon: enum {
		C,
	},
}

Box :: struct($T: typeid) {
	v: T,
}

Un :: union {
	P,
	Kind,
}

take_kind :: proc(k: Kind) {}
take_p :: proc(p: P, q := 0) {}
take_ptr :: proc(p: ^P) {}
take_any :: proc(v: any) {}
take_un :: proc(u: Un) {}
take_var :: proc(ps: ..P) {}
take_gen :: proc(v: $T) {}
take_i :: proc(p: P) {}
take_f :: proc(k: Kind) {}
group :: proc {
	take_i,
	take_f,
}

`

qualify_source :: proc(body: string) -> string {
	return strings.concatenate({QUALIFY_PRELUDE, body}, context.temp_allocator)
}

// body with `{*}` for the cursor, in a procedure with a local k, and the expected body.
expect_qualify :: proc(t: ^testing.T, title, body, expected: string) {
	source := test.Source {
		main = qualify_source(body),
		config = {enable_code_action_qualify = true},
	}
	test.expect_action_applied(t, &source, title, qualify_source(expected))
}

expect_no_qualify :: proc(t: ^testing.T, title, body: string) {
	source := test.Source {
		main = qualify_source(body),
		config = {enable_code_action_qualify = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
qualify_enum_in_a_declaration_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		QUALIFY,
		"main :: proc() {\n\tk: Kind = .{*}A\n\t_ = k\n}\n",
		"main :: proc() {\n\tk: Kind = Kind.A\n\t_ = k\n}\n",
	)
	expect_qualify(
		t,
		DROP_ENUM,
		"main :: proc() {\n\tk: Kind = Ki{*}nd.A\n\t_ = k\n}\n",
		"main :: proc() {\n\tk: Kind = .A\n\t_ = k\n}\n",
	)
	expect_qualify(
		t,
		DROP_ENUM,
		"main :: proc() {\n\tk: Kind = Kind.{*}A\n\t_ = k\n}\n",
		"main :: proc() {\n\tk: Kind = .A\n\t_ = k\n}\n",
	)
}

@(test)
qualify_enum_in_an_assignment_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		QUALIFY,
		"main :: proc() {\n\tk: Kind\n\tk = .{*}A\n}\n",
		"main :: proc() {\n\tk: Kind\n\tk = Kind.A\n}\n",
	)
	expect_qualify(
		t,
		DROP_ENUM,
		"main :: proc() {\n\tk: Kind\n\tk = Kind.{*}A\n}\n",
		"main :: proc() {\n\tk: Kind\n\tk = .A\n}\n",
	)
}

@(test)
qualify_enum_in_a_call_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		QUALIFY,
		"main :: proc() {\n\ttake_kind(.{*}A)\n}\n",
		"main :: proc() {\n\ttake_kind(Kind.A)\n}\n",
	)
	expect_qualify(
		t,
		DROP_ENUM,
		"main :: proc() {\n\ttake_kind(Kind.{*}A)\n}\n",
		"main :: proc() {\n\ttake_kind(.A)\n}\n",
	)
}

@(test)
qualify_enum_in_a_comparison_and_a_case_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		QUALIFY,
		"f :: proc(k: Kind) -> bool {\n\treturn k == .{*}A\n}\n",
		"f :: proc(k: Kind) -> bool {\n\treturn k == Kind.A\n}\n",
	)
	expect_qualify(
		t,
		DROP_ENUM,
		"f :: proc(k: Kind) -> bool {\n\treturn k == Kind.{*}A\n}\n",
		"f :: proc(k: Kind) -> bool {\n\treturn k == .A\n}\n",
	)
	expect_qualify(
		t,
		QUALIFY,
		"f :: proc(k: Kind) {\n\tswitch k {\n\tcase .{*}A:\n\tcase .B:\n\t}\n}\n",
		"f :: proc(k: Kind) {\n\tswitch k {\n\tcase Kind.A:\n\tcase .B:\n\t}\n}\n",
	)
	expect_qualify(
		t,
		DROP_ENUM,
		"f :: proc(k: Kind) {\n\tswitch k {\n\tcase Kind.{*}A:\n\tcase .B:\n\t}\n}\n",
		"f :: proc(k: Kind) {\n\tswitch k {\n\tcase .A:\n\tcase .B:\n\t}\n}\n",
	)
}

@(test)
qualify_enum_in_a_field_and_a_return_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		QUALIFY,
		"main :: proc() {\n\tq := Q{k = .{*}A}\n\t_ = q\n}\n",
		"main :: proc() {\n\tq := Q{k = Kind.A}\n\t_ = q\n}\n",
	)
	expect_qualify(
		t,
		DROP_ENUM,
		"main :: proc() {\n\tq := Q{k = Kind.{*}A}\n\t_ = q\n}\n",
		"main :: proc() {\n\tq := Q{k = .A}\n\t_ = q\n}\n",
	)
	expect_qualify(
		t,
		QUALIFY,
		"f :: proc() -> Kind {\n\treturn .{*}A\n}\n",
		"f :: proc() -> Kind {\n\treturn Kind.A\n}\n",
	)
	expect_qualify(
		t,
		DROP_ENUM,
		"f :: proc() -> Kind {\n\treturn Kind.{*}A\n}\n",
		"f :: proc() -> Kind {\n\treturn .A\n}\n",
	)
}

@(test)
qualify_enum_in_a_bit_set_literal_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		QUALIFY,
		"main :: proc() {\n\ts := Set{.{*}A}\n\t_ = s\n}\n",
		"main :: proc() {\n\ts := Set{Kind.A}\n\t_ = s\n}\n",
	)
	expect_qualify(
		t,
		DROP_ENUM,
		"main :: proc() {\n\ts := Set{Kind.{*}A}\n\t_ = s\n}\n",
		"main :: proc() {\n\ts := Set{.A}\n\t_ = s\n}\n",
	)
}

@(test)
qualify_enum_of_another_package_both_ways :: proc(t: ^testing.T) {
	packages := []test.Package {
		{pkg = "other", source = "package other\nKind :: enum {\n\tA,\n}\ntake :: proc(k: Kind) {}\n"},
	}
	forward := test.Source {
		main = "package test\nimport \"core:other\"\nmain :: proc() {\n\tother.take(.{*}A)\n}\n",
		packages = packages,
		collections = {"core" = "test"},
		config = {enable_code_action_qualify = true},
	}
	test.expect_action_applied(
		t,
		&forward,
		QUALIFY,
		"package test\nimport \"core:other\"\nmain :: proc() {\n\tother.take(other.Kind.A)\n}\n",
	)
	back := test.Source {
		main = "package test\nimport \"core:other\"\nmain :: proc() {\n\tother.take(other.Kind.{*}A)\n}\n",
		packages = packages,
		collections = {"core" = "test"},
		config = {enable_code_action_qualify = true},
	}
	test.expect_action_applied(
		t,
		&back,
		DROP_ENUM,
		"package test\nimport \"core:other\"\nmain :: proc() {\n\tother.take(.A)\n}\n",
	)
}

@(test)
qualify_enum_refuses_an_unknown_expected_type :: proc(t: ^testing.T) {
	expect_no_qualify(t, DROP_ENUM, "main :: proc() {\n\tx := Kind.{*}A\n\t_ = x\n}\n")
	expect_no_qualify(t, DROP_ENUM, "main :: proc() {\n\ttake_any(Kind.{*}A)\n}\n")
	expect_no_qualify(t, DROP_ENUM, "main :: proc() {\n\ttake_gen(Kind.{*}A)\n}\n")
	expect_no_qualify(t, DROP_ENUM, "main :: proc() {\n\tgroup(Kind.{*}A)\n}\n")
	expect_no_qualify(t, DROP_ENUM, "main :: proc() {\n\tu: Un = Kind.{*}A\n\t_ = u\n}\n")
	expect_no_qualify(t, DROP_ENUM, "f :: proc(k: Other) -> bool {\n\treturn int(k) == int(Kind.{*}A)\n}\n")
	expect_no_qualify(t, DROP_ENUM, "main :: proc() {\n\t_ = int(Kind.{*}A)\n}\n")
}

@(test)
qualify_enum_refuses_a_shadowed_or_anonymous_type :: proc(t: ^testing.T) {
	expect_no_qualify(t, QUALIFY, "f :: proc(k: Kind) {\n\tKind := 1\n\t_ = Kind\n\ttake_kind(.{*}A)\n}\n")
	expect_no_qualify(t, QUALIFY, "main :: proc() {\n\tq: Q\n\tq.anon = .{*}C\n}\n")
	expect_no_qualify(t, QUALIFY, "main :: proc() {\n\tx: enum {\n\t\tC,\n\t}\n\tx = .{*}C\n}\n")
}

@(test)
qualify_literal_in_a_declaration_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		DROP_LIT,
		"main :: proc() {\n\tv: P = P{{*}1, 2}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv: P = {1, 2}\n\t_ = v\n}\n",
	)
	expect_qualify(
		t,
		ADD_LIT,
		"main :: proc() {\n\tv: P = {{*}1, 2}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv: P = P{1, 2}\n\t_ = v\n}\n",
	)
}

@(test)
qualify_literal_at_package_scope_both_ways :: proc(t: ^testing.T) {
	expect_qualify(t, DROP_LIT, "v: P = P{{*}1, 2}\n", "v: P = {1, 2}\n")
	expect_qualify(t, ADD_LIT, "v: P = {{*}1, 2}\n", "v: P = P{1, 2}\n")
}

@(test)
qualify_literal_of_an_unnamed_type_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		DROP_LIT,
		"main :: proc() {\n\tv: []int = []int{{*}1, 2}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv: []int = {1, 2}\n\t_ = v\n}\n",
	)
	expect_qualify(
		t,
		ADD_LIT,
		"main :: proc() {\n\tv: []int = {{*}1, 2}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv: []int = []int{1, 2}\n\t_ = v\n}\n",
	)
}

@(test)
qualify_literal_in_a_parameter_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		DROP_LIT,
		"main :: proc() {\n\ttake_p(P{{*}1, 2})\n}\n",
		"main :: proc() {\n\ttake_p({1, 2})\n}\n",
	)
	expect_qualify(
		t,
		ADD_LIT,
		"main :: proc() {\n\ttake_p({{*}1, 2})\n}\n",
		"main :: proc() {\n\ttake_p(P{1, 2})\n}\n",
	)
	expect_qualify(
		t,
		ADD_LIT,
		"main :: proc() {\n\ttake_p(p = {{*}1, 2})\n}\n",
		"main :: proc() {\n\ttake_p(p = P{1, 2})\n}\n",
	)
}

@(test)
qualify_literal_in_a_field_and_an_element_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		DROP_LIT,
		"main :: proc() {\n\tq := Q{p = P{{*}1, 2}}\n\t_ = q\n}\n",
		"main :: proc() {\n\tq := Q{p = {1, 2}}\n\t_ = q\n}\n",
	)
	expect_qualify(
		t,
		ADD_LIT,
		"main :: proc() {\n\tq := Q{p = {{*}1, 2}}\n\t_ = q\n}\n",
		"main :: proc() {\n\tq := Q{p = P{1, 2}}\n\t_ = q\n}\n",
	)
	expect_qualify(
		t,
		DROP_LIT,
		"main :: proc() {\n\tv := []P{P{{*}1, 2}}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv := []P{{1, 2}}\n\t_ = v\n}\n",
	)
	expect_qualify(
		t,
		ADD_LIT,
		"main :: proc() {\n\tv := []P{{{*}1, 2}}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv := []P{P{1, 2}}\n\t_ = v\n}\n",
	)
}

@(test)
qualify_literal_in_a_return_and_an_assignment_both_ways :: proc(t: ^testing.T) {
	expect_qualify(
		t,
		DROP_LIT,
		"f :: proc() -> (P, bool) {\n\treturn P{{*}1, 2}, true\n}\n",
		"f :: proc() -> (P, bool) {\n\treturn {1, 2}, true\n}\n",
	)
	expect_qualify(
		t,
		ADD_LIT,
		"f :: proc() -> (P, bool) {\n\treturn {{*}1, 2}, true\n}\n",
		"f :: proc() -> (P, bool) {\n\treturn P{1, 2}, true\n}\n",
	)
	expect_qualify(
		t,
		DROP_LIT,
		"main :: proc() {\n\tv: P\n\tv = P{{*}1, 2}\n}\n",
		"main :: proc() {\n\tv: P\n\tv = {1, 2}\n}\n",
	)
	expect_qualify(
		t,
		ADD_LIT,
		"main :: proc() {\n\tv: P\n\tv = {{*}1, 2}\n}\n",
		"main :: proc() {\n\tv: P\n\tv = P{1, 2}\n}\n",
	)
}

@(test)
qualify_literal_of_another_package_both_ways :: proc(t: ^testing.T) {
	packages := []test.Package {
		{pkg = "other", source = "package other\nP :: struct {\n\tx: int,\n}\ntake :: proc(p: P) {}\n"},
	}
	forward := test.Source {
		main = "package test\nimport \"core:other\"\nmain :: proc() {\n\tother.take({{*}1})\n}\n",
		packages = packages,
		collections = {"core" = "test"},
		config = {enable_code_action_qualify = true},
	}
	test.expect_action_applied(
		t,
		&forward,
		ADD_LIT,
		"package test\nimport \"core:other\"\nmain :: proc() {\n\tother.take(other.P{1})\n}\n",
	)
	back := test.Source {
		main = "package test\nimport \"core:other\"\nmain :: proc() {\n\tother.take(other.P{{*}1})\n}\n",
		packages = packages,
		collections = {"core" = "test"},
		config = {enable_code_action_qualify = true},
	}
	test.expect_action_applied(
		t,
		&back,
		DROP_LIT,
		"package test\nimport \"core:other\"\nmain :: proc() {\n\tother.take({1})\n}\n",
	)
}

@(test)
qualify_literal_refuses_a_place_with_no_type :: proc(t: ^testing.T) {
	expect_no_qualify(t, DROP_LIT, "main :: proc() {\n\tx := P{{*}}\n\t_ = x\n}\n")
	expect_no_qualify(t, DROP_LIT, "main :: proc() {\n\t_ = P{{*}1, 2}.x\n}\n")
	expect_no_qualify(t, DROP_LIT, "main :: proc() {\n\tv := P{{*}} == P{}\n\t_ = v\n}\n")
}

@(test)
qualify_literal_refuses_a_place_of_another_type :: proc(t: ^testing.T) {
	expect_no_qualify(t, DROP_LIT, "main :: proc() {\n\tu: Un = P{{*}1, 2}\n\t_ = u\n}\n")
	expect_no_qualify(t, DROP_LIT, "main :: proc() {\n\ttake_any(P{{*}1, 2})\n}\n")
	expect_no_qualify(t, DROP_LIT, "main :: proc() {\n\ttake_un(P{{*}1, 2})\n}\n")
	expect_no_qualify(t, DROP_LIT, "main :: proc() {\n\ttake_gen(P{{*}1, 2})\n}\n")
	expect_no_qualify(t, DROP_LIT, "main :: proc() {\n\ttake_var(P{{*}1, 2})\n}\n")
	expect_no_qualify(t, DROP_LIT, "main :: proc() {\n\tgroup(P{{*}1, 2})\n}\n")
}

@(test)
qualify_literal_add_refuses_a_header :: proc(t: ^testing.T) {
	expect_no_qualify(t, ADD_LIT, "main :: proc() {\n\tif v: P = {{*}1, 2}; v.x > 0 {\n\t}\n}\n")
}

@(test)
qualify_literal_add_refuses_a_shadowed_type :: proc(t: ^testing.T) {
	expect_no_qualify(t, ADD_LIT, "main :: proc() {\n\tP2 := 1\n\t_ = P2\n\tP := 1\n\t_ = P\n\ttake_p({{*}1, 2})\n}\n")
}

@(test)
qualify_literal_add_refuses_a_generic_field :: proc(t: ^testing.T) {
	expect_no_qualify(t, ADD_LIT, "main :: proc() {\n\tb := Box(P){v = {{*}1, 2}}\n\t_ = b\n}\n")
}

@(test)
qualify_off_with_its_flag :: proc(t: ^testing.T) {
	cases := [][2]string {
		{QUALIFY, "main :: proc() {\n\tk: Kind = .{*}A\n\t_ = k\n}\n"},
		{DROP_ENUM, "main :: proc() {\n\tk: Kind = Kind.{*}A\n\t_ = k\n}\n"},
		{ADD_LIT, "main :: proc() {\n\tv: P = {{*}1, 2}\n\t_ = v\n}\n"},
		{DROP_LIT, "main :: proc() {\n\tv: P = P{{*}1, 2}\n\t_ = v\n}\n"},
	}
	for item in cases {
		source := test.Source {
			main = qualify_source(item[1]),
			config = {enable_code_action_qualify = false},
		}
		test.expect_action_missing(t, &source, item[0])
	}
}
