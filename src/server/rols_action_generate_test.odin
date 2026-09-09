#+private file
package server

import "core:fmt"
import "core:odin/ast"
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
	if strings.has_suffix(document.fullpath, "_test.odin") {
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
	if slice.contains(attribute_names(decl.attributes[:]), "test") || is_file_private(decl.attributes[:]) {
		return
	}

	base := path.base(document.fullpath)
	test_path := path.join(
		{
			document.package_name,
			strings.concatenate({strings.trim_suffix(base, ".odin"), "_test.odin"}, context.temp_allocator),
		},
		context.temp_allocator,
	)
	if !ctx.config.client_create_file_support && !package_file_exists(test_path, ctx.files) {
		return
	}

	src := document.ast.src
	proc_name := node_text(src, decl.names[0])
	unit := indent_unit(src, "", nil)

	args := zero_values(ctx, lit.type.params)
	results := zero_values(ctx, lit.type.results)
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
	for name, i in names {
		fmt.sbprintf(&sb, "%stesting.expect_value(t, %s, %s)\n", unit, name, results[i])
	}
	strings.write_string(&sb, "}\n")

	uri := common.create_uri(test_path, context.temp_allocator)
	changes := make(Changes, context.temp_allocator)
	edit, ok := append_to_package_file(
		&changes,
		document.ast.pkg_name,
		uri.uri,
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

zero_values :: proc(ctx: ^ActionContext, fields: ^ast.Field_List) -> []string {
	if fields == nil {
		return {}
	}
	types := field_types(fields.list)
	values := make([]string, len(types), context.temp_allocator)
	for type, i in types {
		symbol, resolved := resolve_type_expression(ctx.ast_context, type)
		values[i] = zero_value_text(symbol, resolved)
	}
	return values
}

// A global of the document or, through the index, of any file of the package.
is_declared :: proc(ctx: ^ActionContext, name: string) -> bool {
	if name in ctx.ast_context.globals {
		return true
	}
	_, indexed := lookup(name, ctx.document.package_name, ctx.document.fullpath)
	return indexed
}
