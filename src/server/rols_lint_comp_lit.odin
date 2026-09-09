package server

import "core:fmt"
import "core:odin/ast"

import "src:common"

lint_struct_literal :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_struct_literal do return
	lit, is_lit := node.derived.(^ast.Comp_Lit)
	// A nested literal without a type takes it from the outer field, which is not resolved here.
	if !is_lit || lit.type == nil do return

	fields := make([dynamic]^ast.Ident, 0, len(lit.elems), context.temp_allocator)
	for elem in lit.elems {
		value, is_value := elem.derived.(^ast.Field_Value)
		if !is_value do continue
		if ident, is_ident := value.field.derived.(^ast.Ident); is_ident {
			append(&fields, ident)
		}
	}
	if len(fields) == 0 do return

	seen := make(map[string]struct{}, len(fields), context.temp_allocator)
	for field in fields {
		if field.name in seen {
			append(
				diags,
				Diagnostic {
					range = common.get_token_range(field, ctx.src),
					severity = .Error,
					code = "duplicate-field",
					message = fmt.tprintf("field '%s' is set twice", field.name),
				},
			)
		}
		seen[field.name] = {}
	}

	names, has_names := struct_field_names(ctx, lit.type)
	if !has_names do return
	for field in fields {
		if field.name in names.set do continue
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(field, ctx.src),
				severity = .Error,
				code = "unknown-field",
				message = fmt.tprintf("'%s' has no field '%s'", names.struct_name, field.name),
			},
		)
	}
}

@(private = "file")
Struct_Fields :: struct {
	struct_name: string,
	set:         map[string]struct{},
}

// Fails for anything whose full field set we cannot see: unresolved types, parametric structs,
// `using` fields pulled in from elsewhere, and raw unions, where naming one field is normal.
@(private = "file")
struct_field_names :: proc(ctx: ^LintContext, type: ^ast.Expr) -> (fields: Struct_Fields, ok: bool) {
	#partial switch _ in type.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
	case:
		return
	}
	resolved := lint_symbols(ctx)[uintptr(type)] or_return
	if resolved.is_unresolved || resolved.symbol == nil do return
	if .PolyType in resolved.symbol.flags do return

	v := resolved.symbol.value.(SymbolStructValue) or_return
	if len(v.usings) > 0 || len(v.unexpanded_usings) > 0 do return
	if .Is_Raw_Union in v.tags do return
	if v.poly != nil do return
	for field_type in v.types {
		if _, is_poly := field_type.derived.(^ast.Poly_Type); is_poly do return
	}

	fields.struct_name = resolved.symbol.name
	fields.set = make(map[string]struct{}, len(v.names), context.temp_allocator)
	for name in v.names {
		fields.set[name] = {}
	}
	return fields, true
}
