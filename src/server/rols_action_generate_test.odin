#+private file
package server

import "base:runtime"

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:os"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

import "src:common"

// On the name of a top-level procedure: a @(test) stub calling it with zero values, appended to the
// <file>_test.odin of the package, which is created when the client can create files.
@(private = "package")
add_generate_test_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_generate_test {
		return
	}
	document := ctx.document
	// `x_test_windows.odin` is a test file as well: the OS suffix follows `_test`.
	base := path.base(document.fullpath)
	suffix := target_suffix(base)
	stem := strings.trim_suffix(strings.trim_suffix(base, ".odin"), suffix)
	if strings.has_suffix(stem, "_test") {
		return
	}
	decl, found := top_decl_at(document, ctx.range.start)
	if !found || len(decl.names) != 1 || len(decl.values) != 1 {
		return
	}
	lit, is_proc := decl.values[0].derived.(^ast.Proc_Lit)
	if !is_proc || lit.type == nil || lit.type.generic || len(lit.where_clauses) > 0 {
		return
	}
	// A `$` nested in a parameter type, as in `^Ctx($Msg)`, leaves `generic` unset but no zero value fits.
	if lit.type.params != nil && strings.contains(node_text(document.ast.src, lit.type.params), "$") {
		return
	}
	if slice.contains(attribute_names(decl.attributes[:]), "test") || file_private(document, decl) {
		return
	}
	// odin builds a `_test.odin` file in every build, and core:testing does not compile on some targets.
	source_oses := build_oses(document.fullpath, document.ast.src)
	if source_oses != {} && source_oses <= NO_TESTING_OSES {
		return
	}

	// The OS suffix goes last, so that the test builds only where the file it tests does.
	test_path := path.join(
		{document.package_name, strings.concatenate({stem, "_test", suffix, ".odin"}, context.temp_allocator)},
		context.temp_allocator,
	)
	if !ctx.config.client_create_file_support && !package_file_exists(test_path, ctx.files) {
		return
	}

	src := document.ast.src
	proc_name := node_text(src, decl.names[0])
	unit := indent_unit(src, "", nil)

	args := call_arguments(ctx, lit.type.params)
	results, results_ok := result_checks(ctx, lit.type.results)
	if !results_ok {
		return
	}
	names := make([]string, len(results), context.temp_allocator)
	for &name, i in names {
		name = "result" if len(results) == 1 else fmt.tprintf("%c", 'a' + i)
	}

	test_name := fmt.tprintf("test_%s", proc_name)
	for i := 2; is_declared(ctx, test_name); i += 1 {
		test_name = fmt.tprintf("test_%s%d", proc_name, i)
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "@(test)\n")
	strings.write_string(&sb, test_name)
	strings.write_string(&sb, " :: proc(t: ^testing.T) {\n")
	strings.write_string(&sb, unit)
	if len(names) > 0 {
		strings.write_string(&sb, strings.join(names, ", ", context.temp_allocator))
		strings.write_string(&sb, " := ")
	}
	strings.write_string(&sb, proc_name)
	strings.write_byte(&sb, '(')
	strings.write_string(&sb, strings.join(args, ", ", context.temp_allocator))
	strings.write_string(&sb, ")\n")
	checks := strings.builder_make(context.temp_allocator)
	for name, i in names {
		if results[i].collection {
			fmt.sbprintf(&sb, "%sdefer delete(%s)\n", unit, name)
			fmt.sbprintf(&checks, "%stesting.expect(t, len(%s) == 0)\n", unit, name)
		} else {
			fmt.sbprintf(&checks, "%stesting.expect_value(t, %s, %s)\n", unit, name, results[i].zero)
		}
	}
	strings.write_string(&sb, strings.to_string(checks))
	strings.write_string(&sb, "}\n")

	// A new test file builds on the targets of its source, less those without core:testing that the package
	// targets, and keeps its `#+private` and `#+vet` tags.
	tags := make([dynamic]tokenizer.Token, context.temp_allocator)
	if !package_file_exists(test_path, ctx.files) {
		for excluded in excluded_test_oses(ctx, source_oses) {
			name := strings.to_lower(fmt.tprint(excluded), context.temp_allocator)
			append(&tags, tokenizer.Token{text = fmt.tprintf("#+build !%s", name)})
		}
	}
	append(&tags, ..document.ast.tags[:])

	uri := common.create_uri(test_path, context.temp_allocator)
	changes := make(Changes, context.temp_allocator)
	edit, ok := append_to_package_file(
		&changes,
		document.ast.pkg_name,
		uri.uri,
		tags[:],
		{`import "core:testing"`},
		strings.to_string(sb),
		ctx.files,
	)
	if !ok {
		return
	}
	append(
		ctx.actions,
		CodeAction{title = fmt.tprintf("Generate test for %s", proc_name), kind = "refactor", edit = edit},
	)
}

// The operating systems the new test file leaves out, one `#+build !os` line each: those without core:testing
// that the source builds on and some other file of the package builds only on, so the package targets them.
excluded_test_oses :: proc(
	ctx: ^ActionContext,
	source_oses: bit_set[runtime.Odin_OS_Type],
) -> bit_set[runtime.Odin_OS_Type] {
	excluded: bit_set[runtime.Odin_OS_Type]
	candidates := source_oses & NO_TESTING_OSES
	if candidates == {} {
		return {}
	}
	for sibling in package_siblings(ctx.document, ctx.files) {
		text := ""
		if len(ctx.files) > 0 {
			for file in ctx.files {
				if file.fullpath == sibling do text = file.text
			}
		} else if data, err := os.read_entire_file(sibling, context.temp_allocator); err == nil {
			text = string(data)
		} else {
			continue
		}
		if oses := build_oses(sibling, text); oses != {} && oses <= NO_TESTING_OSES {
			excluded += oses & candidates
		}
	}
	return excluded
}

// Zero values for the parameters without a default value and not variadic. A parameter after a
// skipped one is passed by name, since its position no longer matches.
call_arguments :: proc(ctx: ^ActionContext, fields: ^ast.Field_List) -> []string {
	args := make([dynamic]string, context.temp_allocator)
	if fields == nil {
		return args[:]
	}
	named := false
	for field in fields.list {
		if field.default_value != nil || field.type == nil || is_variadic(field.type) {
			named = true
			continue
		}
		symbol, resolved := resolve_type_expression(ctx.ast_context, field.type)
		value := zero_value_text(symbol, resolved)
		for i in 0 ..< max(len(field.names), 1) {
			if named && i < len(field.names) {
				append(&args, fmt.tprintf("%s = %s", node_text(ctx.document.ast.src, field.names[i]), value))
			} else {
				append(&args, value)
			}
		}
	}
	return args[:]
}

is_variadic :: proc(type: ^ast.Expr) -> bool {
	_, ok := type.derived.(^ast.Ellipsis)
	return ok
}

Result_Check :: struct {
	// A slice, dynamic array or map: not comparable, so the test checks its length and deletes it.
	collection: bool,
	// The expected value for testing.expect_value otherwise.
	zero:       string,
}

// testing.expect_value needs a comparable type and cannot infer a bare `{}`, so an aggregate zero value
// is spelled `E{}`. That fails (ok is false) for a type the test file cannot spell, a package-qualified
// or multi-line one, and for a type that is not comparable, such as a struct holding a slice.
result_checks :: proc(ctx: ^ActionContext, fields: ^ast.Field_List) -> (checks: []Result_Check, ok: bool) {
	if fields == nil {
		return {}, true
	}
	types := field_types(fields.list)
	checks = make([]Result_Check, len(types), context.temp_allocator)
	for type, i in types {
		if type == nil {
			return nil, false
		}
		symbol, resolved := resolve_type_expression(ctx.ast_context, type)
		if resolved && symbol.pointers == 0 {
			#partial switch _ in symbol.value {
			case SymbolSliceValue, SymbolDynamicArrayValue, SymbolMapValue:
				// `delete` has no overload for a fixed-capacity dynamic array.
				if v, fixed := symbol.value.(SymbolDynamicArrayValue); fixed && v.cap != nil {
					return nil, false
				}
				checks[i].collection = true
				continue
			}
		}
		if resolved && !is_comparable(ctx.ast_context, symbol, 0) {
			return nil, false
		}
		checks[i].zero = zero_value_text(symbol, resolved)
		if checks[i].zero == "{}" {
			text := node_text(ctx.document.ast.src, type)
			if strings.contains_any(text, ".\n") || names_file_private(ctx.document, type) {
				return nil, false
			}
			checks[i].zero = strings.concatenate({text, "{}"}, context.temp_allocator)
		}
	}
	return checks, true
}

// Whether type names a top-level declaration private to the document's file, which the test file cannot see.
names_file_private :: proc(document: ^Document, type: ^ast.Expr) -> bool {
	private_names := file_private_names(document)
	for use in collect_ident_uses(type) {
		if use.ident.name in private_names {
			return true
		}
	}
	return false
}

// intrinsics.type_is_comparable: false for a slice, dynamic array, map, `any`, #soa type or
// #raw_union struct, and for an aggregate holding one. A #raw_union struct is comparable only with
// simple fields, which this does not check. A field type that does not resolve counts as not comparable.
is_comparable :: proc(ast_context: ^AstContext, symbol: Symbol, depth: int) -> bool {
	if symbol.pointers > 0 {
		return true
	}
	if depth > 16 || .Soa in symbol.flags {
		return false
	}
	element_types: []^ast.Expr
	#partial switch v in symbol.value {
	case SymbolSliceValue, SymbolDynamicArrayValue, SymbolMapValue:
		return false
	case SymbolBasicValue:
		return v.ident.name != "any"
	case SymbolStructValue:
		if .Is_Raw_Union in v.tags {
			return false
		}
		element_types = v.types
	case SymbolUnionValue:
		element_types = v.types
	case SymbolFixedArrayValue:
		set_ast_package_from_symbol_scoped(ast_context, symbol)
		element, resolved := resolve_type_expression(ast_context, v.expr)
		return resolved && is_comparable(ast_context, element, depth + 1)
	case:
		return true
	}
	for type in element_types {
		set_ast_package_from_symbol_scoped(ast_context, symbol)
		element, resolved := resolve_type_expression(ast_context, type)
		if !resolved || !is_comparable(ast_context, element, depth + 1) {
			return false
		}
	}
	return true
}

// A global of the document or, through the index, of any file of the package.
is_declared :: proc(ctx: ^ActionContext, name: string) -> bool {
	if name in ctx.ast_context.globals {
		return true
	}
	_, indexed := lookup(name, ctx.document.package_name, ctx.document.fullpath)
	return indexed
}
