package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

import "src:common"

@(private = "file")
Naming_Rule :: enum {
	Snake,
	Screaming,
	Ada,
	Snake_Or_Screaming,
}

@(private = "file")
rule_names := [Naming_Rule]string {
	.Snake              = "snake_case",
	.Screaming          = "SCREAMING_SNAKE_CASE",
	.Ada                = "Ada_Case",
	.Snake_Or_Screaming = "snake_case or SCREAMING_SNAKE_CASE",
}

@(private = "file")
Decl_Kind :: enum {
	Procedure,
	Type,
	Constant,
	Bool, // `true` or `false`: a flag reads like a variable or a constant
	Alias,
}

lint_naming :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_naming do return
	if node in ctx.skip do return

	#partial switch n in node.derived {
	case ^ast.Foreign_Block_Decl:
		// The library dictates every name in a foreign block.
		skip_subtree(ctx, n.body)
	case ^ast.Value_Decl:
		if has_external_name(n.attributes[:]) do return
		for name, i in n.names {
			ident := name.derived.(^ast.Ident) or_continue
			if ident.name == "main" do continue
			if n.is_mutable {
				check_name(ctx, diags, ident, "variable", .Snake)
				continue
			}
			if i >= len(n.values) do continue
			switch decl_kind(ctx, n.values[i]) {
			case .Procedure:
				check_name(ctx, diags, ident, "procedure", .Snake)
			case .Type:
				check_c_name(ctx, diags, ident, "type", .Ada)
			case .Constant:
				// A proc-local constant reads as a local, so SCREAMING_SNAKE_CASE is not expected.
				if is_top_level(ctx, n) do check_c_name(ctx, diags, ident, "constant", .Screaming)
			case .Bool:
				if is_top_level(ctx, n) do check_c_name(ctx, diags, ident, "constant", .Snake_Or_Screaming)
			case .Alias:
			}
		}
	case ^ast.Proc_Type:
		if n.params == nil do return
		// A C callback's parameter names come from the C declaration.
		if convention, is_string := n.calling_convention.(string); is_string {
			convention = strings.trim(convention, "\"`")
			if convention != "odin" && convention != "contextless" do return
		}
		for field in n.params.list {
			if .Using in field.flags do continue
			for name in field.names {
				ident := name.derived.(^ast.Ident) or_continue
				check_name(ctx, diags, ident, "parameter", .Snake)
			}
		}
	case ^ast.Struct_Type:
		if n.fields == nil do return
		for field in n.fields.list {
			// A tag string such as `json:"fooBar"` ties the field name to an external format.
			if field.tag.text != "" do continue
			for name in field.names {
				ident := name.derived.(^ast.Ident) or_continue
				check_c_name(ctx, diags, ident, "field", .Snake)
			}
		}
	case ^ast.Bit_Field_Type:
		for field in n.fields {
			ident := field.name.derived.(^ast.Ident) or_continue
			check_c_name(ctx, diags, ident, "field", .Snake)
		}
	case ^ast.Enum_Type:
		for field in n.fields {
			expr := field
			if field_value, ok := field.derived.(^ast.Field_Value); ok do expr = field_value.field
			ident := expr.derived.(^ast.Ident) or_continue
			check_c_name(ctx, diags, ident, "enum member", .Ada)
		}
	}
}

@(private = "file")
decl_kind :: proc(ctx: ^LintContext, value: ^ast.Expr) -> Decl_Kind {
	#partial switch v in value.derived {
	case ^ast.Proc_Lit, ^ast.Proc_Group:
		return .Procedure
	case ^ast.Struct_Type,
	     ^ast.Union_Type,
	     ^ast.Enum_Type,
	     ^ast.Bit_Field_Type,
	     ^ast.Distinct_Type,
	     ^ast.Proc_Type,
	     ^ast.Pointer_Type,
	     ^ast.Multi_Pointer_Type,
	     ^ast.Array_Type,
	     ^ast.Dynamic_Array_Type,
	     ^ast.Map_Type,
	     ^ast.Bit_Set_Type,
	     ^ast.Matrix_Type,
	     ^ast.Helper_Type,
	     ^ast.Typeid_Type:
		return .Type
	case ^ast.Call_Expr:
		// `#config(...)`, `#load(...)`: the name follows the call. `Vector(f32)`: a type.
		if _, is_directive := v.expr.derived.(^ast.Basic_Directive); is_directive do return .Alias
		callee, resolved := lint_symbols(ctx)[uintptr(v.expr)]
		// rols: in inactive code the callee may stand for a platform variant of another kind.
		if resolved && ambiguous_in_inactive(ctx, callee.symbol) do return .Alias
		// `f32(48)`, `Meters(2)`: a cast of a literal is a constant.
		if len(v.args) == 1 && !has_poly_params(ctx, v.expr) {
			if resolved && callee.symbol != nil && callee.symbol.type == .Keyword do return .Constant
			if _, is_lit := unparen(v.args[0]).derived.(^ast.Basic_Lit); is_lit do return .Constant
		}
		if decl_kind(ctx, v.expr) == .Type do return .Type
		return .Constant
	case ^ast.Ident, ^ast.Selector_Expr:
		if ident, is_ident := value.derived.(^ast.Ident); is_ident && (ident.name == "true" || ident.name == "false") {
			return .Bool
		}
		resolved, is_resolved := lint_symbols(ctx)[uintptr(value)]
		if !is_resolved || resolved.symbol.value == nil do return .Alias
		// rols: in inactive code the name may stand for a platform variant of another kind.
		if ambiguous_in_inactive(ctx, resolved.symbol) do return .Alias
		#partial switch resolved.symbol.type {
		case .Function, .Package:
			return .Alias
		case .Constant, .Variable, .EnumMember, .Field:
			return .Constant
		}
		if .Variable in resolved.symbol.flags do return .Constant
		// rols: the resolver drops .Variable from a symbol whose value is an identifier, so `pf :: PLATFORM`
		// with `PLATFORM :: IMPL` (a value) reads as a type. Follow the alias chain to its source.
		if aliases_value(ctx, resolved.symbol.value_expr) do return .Constant
		return .Type
	}
	return .Constant
}

// Whether expr names, through a chain of identifiers declared in this file, a symbol flagged .Variable.
@(private = "file")
aliases_value :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> bool {
	expr := expr
	for _ in 0 ..< 8 {
		if expr == nil do return false
		ident, is_ident := expr.derived.(^ast.Ident)
		if !is_ident do return false
		resolved, ok := lint_symbols(ctx)[uintptr(ident)]
		if !ok || resolved.symbol == nil do return false
		if .Variable in resolved.symbol.flags do return true
		expr = resolved.symbol.value_expr
	}
	return false
}

// `Small_Array(16, Item)` instantiates a polymorphic type, so its literal argument is not a cast.
@(private = "file")
has_poly_params :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> bool {
	resolved, ok := lint_symbols(ctx)[uintptr(expr)]
	if !ok || resolved.symbol == nil do return false
	#partial switch value in resolved.symbol.value {
	case SymbolStructValue:
		return value.poly != nil
	case SymbolUnionValue:
		return value.poly != nil
	}
	return false
}

@(private = "file")
check_name :: proc(
	ctx: ^LintContext,
	diags: ^[dynamic]Diagnostic,
	ident: ^ast.Ident,
	what: string,
	rule: Naming_Rule,
) {
	if ident.name == "_" || conforms(ident.name, rule) do return
	append(
		diags,
		Diagnostic {
			range = common.get_token_range(ident, ctx.src),
			severity = .Information,
			code = "naming",
			message = fmt.tprintf("%s names are %s: %s", what, rule_names[rule], ident.name),
		},
	)
}

// A type, field, enum member or constant name in a package that binds a C library may mirror a C name.
@(private = "file")
check_c_name :: proc(
	ctx: ^LintContext,
	diags: ^[dynamic]Diagnostic,
	ident: ^ast.Ident,
	what: string,
	rule: Naming_Rule,
) {
	if ident.name == "_" || conforms(ident.name, rule) do return
	if ctx.foreign_import == nil do ctx.foreign_import = package_binds_c(ctx)
	if ctx.foreign_import.? do return
	check_name(ctx, diags, ident, what, rule)
}

// Whether a file of the package has a `foreign import` or imports `core:dynlib`: a binding package may declare its
// library in one file and the C types in another.
@(private = "file")
package_binds_c :: proc(ctx: ^LintContext) -> bool {
	if tokens_bind_c(ctx.src, ctx.document.ast.pkg_name) do return true
	for file in sibling_values(ctx).files {
		if tokens_bind_c(file.text, ctx.document.ast.pkg_name) do return true
	}
	return false
}

// Whether src, read as a file of package pkg_name, has a `foreign import` or an import of `core:dynlib`. Its tokens
// tell, without a parse: both can only stand at file scope, and a comment or a string holds neither.
@(private = "file")
tokens_bind_c :: proc(src, pkg_name: string) -> bool {
	// Most files hold neither text, so they are not scanned.
	if !strings.contains(src, "foreign import") && !strings.contains(src, "core:dynlib") do return false
	silent :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
	t: tokenizer.Tokenizer
	tokenizer.init(&t, src, "", silent)
	prev, before: tokenizer.Token_Kind
	for {
		token := tokenizer.scan(&t)
		#partial switch token.kind {
		case .EOF:
			return false
		case .Comment:
			continue
		case .Ident:
			if prev == .Package && token.text != pkg_name do return false
		case .Import:
			if prev == .Foreign do return true
		case .String:
			// `import "core:dynlib"` or `import name "core:dynlib"`
			from_import := prev == .Import || (prev == .Ident && before == .Import)
			if from_import && strings.trim(token.text, "\"`") == "core:dynlib" do return true
		}
		prev, before = token.kind, prev
	}
}

// Non-ASCII names conform. A single uppercase letter (`N`, `T`) passes snake_case.
@(private = "file")
conforms :: proc(name: string, rule: Naming_Rule) -> bool {
	for c in transmute([]u8)name do if c >= 0x80 do return true
	switch rule {
	case .Snake:
		if len(name) == 1 && is_upper(name[0]) do return true
		for c in transmute([]u8)name do if !(is_lower(c) || is_digit(c) || c == '_') do return false
		return true
	case .Screaming:
		has_letter: bool
		for c in transmute([]u8)name {
			if is_upper(c) do has_letter = true
			else if !(is_digit(c) || c == '_') do return false
		}
		return has_letter
	case .Snake_Or_Screaming:
		return conforms(name, .Snake) || conforms(name, .Screaming)
	case .Ada:
		// `_1`: a name cannot start with a digit. `_Private`: snake_case and SCREAMING_SNAKE_CASE accept
		// the leading underscore, so this rule does too.
		name := strings.trim_left(name, "_")
		if name == "" do return true
		for segment in strings.split(name, "_", context.temp_allocator) {
			if len(segment) == 0 || !(is_upper(segment[0]) || is_digit(segment[0])) do return false
		}
		return true
	}
	return true
}

@(private = "file")
is_upper :: proc(c: u8) -> bool {
	return 'A' <= c && c <= 'Z'
}
@(private = "file")
is_lower :: proc(c: u8) -> bool {
	return 'a' <= c && c <= 'z'
}
@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return '0' <= c && c <= '9'
}

@(private = "file")
has_external_name :: proc(attributes: []^ast.Attribute) -> bool {
	for name in attribute_names(attributes) {
		if name == "export" || name == "link_name" || strings.has_prefix(name, "objc_") do return true
	}
	return false
}

@(private = "package")
skip_subtree :: proc(ctx: ^LintContext, root: ^ast.Node) {
	if root == nil do return
	visitor := ast.Visitor {
		data = ctx,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			(^LintContext)(visitor.data).skip[node] = {}
			return visitor
		},
	}
	ast.walk(&visitor, root)
}
