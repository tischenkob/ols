package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "src:common"

LintContext :: struct {
	document:    ^Document,
	config:      ^common.Config,
	src:         string,
	symbols:     Maybe(SymbolAndNodeMap),
	// Names the file uses as values (see `value_names`), built on first use.
	value_names: Maybe(map[string]struct{}),
	// Names the file's calls give their arguments (see `named_arguments`), built on first use.
	named_args:  Maybe(map[string]struct{}),
	// Nodes a lint excluded while visiting their parent: deferred statements, proc literals whose signature
	// an attribute fixes, callback literals, and procedures the file uses as values.
	skip:        map[^ast.Node]struct{},
	fixes:       [dynamic]Lint_Fix,
}

// A single-edit fix for one diagnostic, offered as a quick fix at the cursor.
Lint_Fix :: struct {
	start, end:  int,
	title, text: string,
	code:        string, // the modernize rule id: the diagnostic code, with a suffix for alternative fixes
}

@(private = "package")
is_top_level :: proc(ctx: ^LintContext, decl: ^ast.Value_Decl) -> bool {
	stmt := top_level_stmt_at(ctx.document.ast.decls[:], decl.pos.offset)
	return stmt != nil && declares(stmt, decl)
}

// The first top-level statement that ends after `offset`. Statements are in source order, so a
// per-node lint finds the one that holds a node without scanning the whole file.
@(private = "package")
top_level_stmt_at :: proc(decls: []^ast.Stmt, offset: int) -> ^ast.Stmt {
	lo, hi := 0, len(decls)
	for lo < hi {
		mid := (lo + hi) / 2
		if decls[mid].end.offset <= offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return decls[lo] if lo < len(decls) else nil
}

// A file-scope `when` holds declarations that are still top level.
@(private = "file")
declares :: proc(stmt: ^ast.Stmt, decl: ^ast.Value_Decl) -> bool {
	if stmt == nil do return false
	#partial switch s in stmt.derived {
	case ^ast.Value_Decl:
		return s == decl
	case ^ast.Block_Stmt:
		for inner in s.stmts do if declares(inner, decl) do return true
	case ^ast.When_Stmt:
		return declares(s.body, decl) || declares(s.else_stmt, decl)
	}
	return false
}

lint_symbols :: proc(ctx: ^LintContext) -> SymbolAndNodeMap {
	symbols, has_symbols := ctx.symbols.?
	if !has_symbols {
		symbols = resolve_entire_file(ctx.document)
		ctx.symbols = symbols
	}
	return symbols
}

// A `{.Unnecessary}` literal inside a lint proc lives on its stack, and run_lints reads the
// diagnostics after the proc returns. These have static storage.
unnecessary_tags := []DiagnosticTag{.Unnecessary}
deprecated_tags := []DiagnosticTag{.Deprecated}

@(private = "file")
lints := [?]proc(_: ^LintContext, _: ^ast.Node, _: ^[dynamic]Diagnostic) {
	lint_self_assignment,
	lint_identical_branches,
	lint_unreachable_code,
	lint_float_equality,
	lint_printf,
	lint_ignored_result,
	lint_unused_parameter,
	lint_unused_variable,
	lint_naming,
	lint_bool_logic,
	lint_no_op,
	lint_loops,
	lint_dead_store,
	lint_allocator,
	lint_sync,
	lint_deprecated,
	lint_test_attribute,
	lint_core_misuse,
	lint_integer_range,
	lint_recursion,
	lint_imports,
	lint_invisible,
	lint_result_order,
	lint_switch,
	lint_redundant_type_assertion,
	lint_calls,
	lint_struct_literal,
	lint_pure_call,
}

@(private = "file")
Walker :: struct {
	ctx:         LintContext,
	diags:       [dynamic]Diagnostic,
	// rols: resolution-dependent lints skip code in `when` branches that the host does not build.
	ast_context: AstContext,
	when_consts: map[string]When_Expr,
	inactive:    int,
}

@(private = "file")
walk_when_branches :: proc(visitor: ^ast.Visitor, w: ^Walker, stmt: ^ast.When_Stmt) {
	active, _ := active_when_block(&w.ast_context, stmt, w.when_consts)
	for branch: ^ast.Stmt = stmt; branch != nil; {
		when_branch, is_when := branch.derived.(^ast.When_Stmt)
		body := when_branch.body if is_when else branch
		if is_when do ast.walk(visitor, when_branch.cond)
		block, is_block := body.derived.(^ast.Block_Stmt)
		is_active := is_block && block == active
		if !is_active do w.inactive += 1
		ast.walk(visitor, body)
		if !is_active do w.inactive -= 1
		branch = when_branch.else_stmt if is_when else nil
	}
}

// One AST walk; every lint sees every node and checks its own config key.
@(private = "file")
walk_lints :: proc(document: ^Document, config: ^common.Config) -> Walker {
	w := Walker {
		ctx = {
			document = document,
			config = config,
			src = string(document.text[:document.used_text]),
			skip = make(map[^ast.Node]struct{}, context.temp_allocator),
			fixes = make([dynamic]Lint_Fix, context.temp_allocator),
		},
		diags = make([dynamic]Diagnostic, context.temp_allocator),
	}
	// rols: nothing in a `#+build ignore` file is built, so nothing in it is linted. A file the host does not build
	// is treated like an inactive branch, since its calls resolve to the host's declarations.
	tags := parser.parse_file_tags(document.ast, context.temp_allocator)
	if tags.ignore {
		return w
	}
	if !should_collect_file(tags) || skip_file(filepath.base(document.fullpath)) {
		w.inactive = 1
	}
	w.ast_context = make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)
	get_globals(document.ast, &w.ast_context)
	w.when_consts = make_when_expr_map()
	register_when_consts_from_globals(&w.when_consts, w.ast_context.globals)
	visitor := ast.Visitor {
		data = &w,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			w := (^Walker)(visitor.data)
			for lint in lints {
				// rols: these lints report errors from resolved declarations, which may belong to another platform.
				if w.inactive > 0 && (lint == lint_calls || lint == lint_struct_literal) do continue
				lint(&w.ctx, node, &w.diags)
			}
			// rols: track which branches of a `when` the host builds.
			if when_stmt, is_when := node.derived.(^ast.When_Stmt); is_when {
				walk_when_branches(visitor, w, when_stmt)
				return nil
			}
			return visitor
		},
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	return w
}

lint_fixes :: proc(document: ^Document, config: ^common.Config) -> []Lint_Fix {
	return walk_lints(document, config).ctx.fixes[:]
}

lint_document :: proc(document: ^Document, config: ^common.Config) -> []Diagnostic {
	w := walk_lints(document, config)
	if parser.parse_file_tags(document.ast, context.temp_allocator).ignore {
		return w.diags[:]
	}
	if config.enable_lint_simplify {
		for s in simplifications(document) {
			append(
				&w.diags,
				Diagnostic {
					range = {
						start = common.get_relative_token_position(s.start, document.text, 0),
						end = common.get_relative_token_position(s.end, document.text, 0),
					},
					severity = .Hint,
					code = s.code,
					message = simplification_message(s),
					tags = unnecessary_tags,
				},
			)
		}
	}
	if config.enable_lint_use_stdlib {
		for m in stdlib_matches(document) {
			append(
				&w.diags,
				Diagnostic {
					range = {
						start = common.get_relative_token_position(m.start, document.text, 0),
						end = common.get_relative_token_position(m.end, document.text, 0),
					},
					severity = .Hint,
					code = "use_stdlib",
					message = fmt.tprintf("Use %s", m.rule.target),
					tags = unnecessary_tags,
				},
			)
		}
	}
	return w.diags[:]
}

run_lints :: proc(document: ^Document, config: ^common.Config) {
	if !config.enable_diagnostics {
		return
	}

	path := document.uri.path
	when ODIN_OS == .Windows {
		path = common.get_case_sensitive_path(path, context.temp_allocator)
	}
	uri := common.create_uri(path, context.temp_allocator)

	remove_diagnostics(.Lint, uri.uri)
	for d in lint_document(document, config) {
		add_diagnostics(.Lint, uri.uri, d)
	}
}

@(private = "file")
lint_self_assignment :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_self_assignment do return
	assign, is_assign := node.derived.(^ast.Assign_Stmt)
	if !is_assign || assign.op.kind != .Eq do return

	before := len(diags)
	defer if len(diags) - before == len(assign.lhs) {
		start, end := whole_lines(ctx.src, node.pos.offset, node.end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove self-assignment", "", "self-assignment"})
	}

	for i in 0 ..< min(len(assign.lhs), len(assign.rhs)) {
		if contains_call(assign.rhs[i]) do continue
		lhs := strip_space(node_text(ctx.src, unparen(assign.lhs[i])))
		if lhs != strip_space(node_text(ctx.src, unparen(assign.rhs[i]))) do continue
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(assign, ctx.src),
				severity = .Warning,
				code = "self-assignment",
				message = fmt.tprintf("%s is assigned to itself", lhs),
			},
		)
	}
}

@(private = "file")
contains_call :: proc(root: ^ast.Expr) -> bool {
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			if _, ok := node.derived.(^ast.Call_Expr); ok {
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
	return found
}

@(private = "file")
lint_identical_branches :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_identical_branches do return

	#partial switch n in node.derived {
	case ^ast.If_Stmt:
		body, body_ok := n.body.derived.(^ast.Block_Stmt)
		if !body_ok || n.else_stmt == nil do return
		else_block, else_ok := n.else_stmt.derived.(^ast.Block_Stmt)
		if !else_ok do return
		if strip_space(block_inner_text(ctx.src, body)) != strip_space(block_inner_text(ctx.src, else_block)) do return
		range := common.get_token_range(n, ctx.src)
		range.end = common.get_token_range(n.cond, ctx.src).end
		append(
			diags,
			Diagnostic {
				range = range,
				severity = .Warning,
				code = "identical-branches",
				message = "if and else branches are identical",
			},
		)
	case ^ast.Ternary_If_Expr:
		if strip_space(node_text(ctx.src, n.x)) != strip_space(node_text(ctx.src, n.y)) do return
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(n, ctx.src),
				severity = .Warning,
				code = "identical-branches",
				message = "both ternary branches are identical",
			},
		)
	}
}

@(private = "file")
lint_unreachable_code :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_unreachable_code do return

	stmts: []^ast.Stmt
	#partial switch n in node.derived {
	case ^ast.Block_Stmt:
		stmts = n.stmts
	case ^ast.Case_Clause:
		stmts = n.body
	case:
		return
	}

	for stmt, i in stmts {
		if i + 1 >= len(stmts) do break
		if !terminates(stmt) do continue
		if only_constants(stmts[i + 1:]) do break
		range := common.get_token_range(stmts[i + 1], ctx.src)
		range.end = common.get_token_range(stmts[len(stmts) - 1], ctx.src).end
		append(
			diags,
			Diagnostic {
				range = range,
				severity = .Hint,
				code = "unreachable-code",
				message = "unreachable code",
				tags = unnecessary_tags,
			},
		)
		start, end := whole_lines(ctx.src, stmts[i + 1].pos.offset, stmts[len(stmts) - 1].end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove unreachable code", "", "unreachable-code"})
		return
	}
}

// The lines fully covering [start, end): grown to the line start when only whitespace precedes,
// and past the newline when only whitespace follows.
@(private = "package")
whole_lines :: proc(src: string, start, end: int) -> (int, int) {
	start, end := start, end
	line_start := start
	for line_start > 0 && src[line_start - 1] != '\n' do line_start -= 1
	if strings.trim_space(src[line_start:start]) == "" do start = line_start

	line_end := end
	for line_end < len(src) && src[line_end] != '\n' do line_end += 1
	if strings.trim_space(src[end:line_end]) == "" do end = min(line_end + 1, len(src))
	return start, end
}

// `x :: proc ...` after a return is hoisted, not dead.
@(private = "file")
only_constants :: proc(stmts: []^ast.Stmt) -> bool {
	for stmt in stmts {
		decl, is_decl := stmt.derived.(^ast.Value_Decl)
		if !is_decl || decl.is_mutable do return false
	}
	return true
}

@(private = "file")
terminates :: proc(stmt: ^ast.Stmt) -> bool {
	#partial switch s in stmt.derived {
	case ^ast.Return_Stmt:
		return true
	case ^ast.Branch_Stmt:
		#partial switch s.tok.kind {
		case .Break, .Continue, .Fallthrough:
			return true
		}
	case ^ast.Expr_Stmt:
		return is_panic_call(s)
	}
	return false
}

@(private = "file")
is_panic_call :: proc(stmt: ^ast.Stmt) -> bool {
	expr_stmt := stmt.derived.(^ast.Expr_Stmt) or_return
	call := expr_stmt.expr.derived.(^ast.Call_Expr) or_return
	callee := call.expr.derived.(^ast.Ident) or_return
	return callee.name == "panic" || callee.name == "unreachable"
}

@(private = "file")
lint_float_equality :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_float_equality do return
	binary, is_binary := node.derived.(^ast.Binary_Expr)
	if !is_binary || (binary.op.kind != .Cmp_Eq && binary.op.kind != .Not_Eq) do return
	if !is_float_operand(ctx, binary.left) && !is_float_operand(ctx, binary.right) do return
	// Comparing with a literal zero or one is a sentinel or flag test, not an arithmetic result.
	if is_zero_or_one_literal(binary.left) || is_zero_or_one_literal(binary.right) do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(binary, ctx.src),
			severity = .Information,
			code = "float-equality",
			message = "comparing floats with == is exact; consider an epsilon",
		},
	)
}

@(private = "file")
is_zero_or_one_literal :: proc(expr: ^ast.Expr) -> bool {
	lit, is_lit := ast.unparen_expr(expr).derived.(^ast.Basic_Lit)
	return is_lit && slice.contains([]string{"0", "0.0", "1", "1.0"}, lit.tok.text)
}

// The resolved-symbol map only holds identifiers and selectors, so an indexed or called float
// is only caught when the other operand is a float.
@(private = "package")
is_float_operand :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> bool {
	expr := expr
	for {
		#partial switch e in expr.derived {
		case ^ast.Paren_Expr:
			expr = e.expr
			continue
		case ^ast.Unary_Expr:
			expr = e.expr
			continue
		}
		break
	}

	#partial switch e in expr.derived {
	case ^ast.Basic_Lit:
		return e.tok.kind == .Float
	case ^ast.Ident, ^ast.Selector_Expr:
		resolved := lint_symbols(ctx)[uintptr(expr)] or_return
		// `T == f32` in a `when` compares types, and a type name resolves to the keyword.
		if resolved.symbol.type == .Keyword do return false
		#partial switch v in resolved.symbol.value {
		case SymbolBasicValue:
			return slice.contains(untyped_map[.Float], v.ident.name)
		case SymbolUntypedValue:
			return v.type == .Float
		}
	}
	return false
}

@(private = "file")
lint_ignored_result :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_ignored_result do return
	if deferred, is_defer := node.derived.(^ast.Defer_Stmt); is_defer {
		ctx.skip[deferred.stmt] = {}
		return
	}
	stmt := node.derived.(^ast.Expr_Stmt) or_else nil
	if stmt == nil || node in ctx.skip do return
	expr := stmt.expr
	for {
		paren := expr.derived.(^ast.Paren_Expr) or_break
		expr = paren.expr
	}
	call, is_call := expr.derived.(^ast.Call_Expr)
	if !is_call do return
	resolved, is_resolved := lint_symbols(ctx)[uintptr(call.expr)]
	if !is_resolved do return
	value, is_proc := resolved.symbol.value.(SymbolProcedureValue)
	if !is_proc do return
	// testing.expect* return bool only for chaining.
	if strings.has_suffix(resolved.symbol.pkg, "/testing") do return

	// A guard that `@(deferred_in)` or `@(deferred_none)` pairs with a cleanup call is used for the call it
	// queues. `deferred_out` and `deferred_in_out` pass the result to the cleanup, so it is still a result.
	for name in attribute_names(value.attributes) {
		if name == "deferred_in" || name == "deferred_none" do return
	}

	// Judge the declared types: a generic instantiation turns `$V` into `bool`, which is not a status.
	results := value.return_types
	if len(value.orig_return_types) == len(results) do results = value.orig_return_types
	// Either tag makes only the last result optional.
	if len(results) > 0 &&
	   len(results[len(results) - 1].names) <= 1 &&
	   (.Optional_Ok in value.tags || .Optional_Allocator_Error in value.tags) {
		results = results[:len(results) - 1]
	}

	for field in results {
		name := must_handle_type_name(ctx, resolved.symbol.pkg, field.type) or_continue
		if names_proc_type(ctx, resolved.symbol.pkg, field.type) do continue
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(stmt, ctx.src),
				severity = .Warning,
				code = "ignored-result",
				message = fmt.tprintf("result of %s is ignored (%s)", node_text(ctx.src, call.expr), name),
			},
		)
		return
	}
}

// A type named like an error that is a procedure type, such as a callback `ErrorProc`, holds no error.
@(private = "file")
names_proc_type :: proc(ctx: ^LintContext, pkg: string, type: ^ast.Expr) -> bool {
	#partial switch t in type.derived {
	case ^ast.Ident:
		if t.name == "bool" do return false
	case ^ast.Selector_Expr:
	case:
		return false
	}
	symbol := resolve_type_in_package(ctx.document, pkg, type) or_return
	_, is_proc := symbol.value.(SymbolProcedureValue)
	return is_proc
}

// Resolves a type written in package `pkg`, which may be another package than the document's.
@(private = "package")
resolve_type_in_package :: proc(document: ^Document, pkg: string, type: ^ast.Expr) -> (Symbol, bool) {
	ast_context := package_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		pkg,
	)
	return resolve_type_expression(&ast_context, type)
}

// A context without locals that resolves names in package `pkg`, seen from the open file.
// It takes the file's fields because code actions hold an `AstContext` rather than the `Document`.
@(private = "package")
package_ast_context :: proc(
	file: ast.File,
	imports: []Package,
	document_package, uri, fullpath, pkg: string,
) -> AstContext {
	ast_context := make_ast_context(file, imports, document_package, uri, fullpath, context.temp_allocator)
	get_globals(file, &ast_context)
	ast_context.current_package = pkg
	return ast_context
}

// bool, unions and anything named like an error must be handled by the caller,
// except Allocator_Error, which delete/free/reserve callers ignore as a matter of course.
// The name is written as this file would write it, where `pkg` is the package that declares the callee.
@(private = "file")
must_handle_type_name :: proc(ctx: ^LintContext, pkg: string, type: ^ast.Expr) -> (string, bool) {
	if type == nil do return "", false
	#partial switch t in type.derived {
	case ^ast.Ident:
		if t.name == "Allocator_Error" do return "", false
		if t.name == "bool" do return t.name, true
		if strings.contains(t.name, "Err") do return qualified_type_name(ctx, pkg, t.name), true
	case ^ast.Selector_Expr:
		if t.field == nil || t.field.name == "Allocator_Error" || !strings.contains(t.field.name, "Err") do return "", false
		base, is_ident := t.expr.derived.(^ast.Ident)
		if !is_ident do return t.field.name, true
		// The indexer replaces the alias in the declaring file with that package's directory.
		if strings.contains(base.name, "/") do return qualified_type_name(ctx, base.name, t.field.name), true
		return fmt.tprintf("%s.%s", base.name, t.field.name), true
	case ^ast.Union_Type:
		return "union", true
	case ^ast.Call_Expr:
		// Maybe(T) is a union spelled as a call.
		if ident, is_ident := t.expr.derived.(^ast.Ident); is_ident && ident.name == "Maybe" do return "Maybe", true
	}
	return "", false
}

// `name` declared in the package in directory `dir`, as this file writes it: bare in its own package,
// else with the import alias, else with the last segment of the directory.
@(private = "file")
qualified_type_name :: proc(ctx: ^LintContext, dir, name: string) -> string {
	if dir == "" || dir == "$builtin" || dir == ctx.document.package_name do return name
	for imp in ctx.document.imports {
		if imp.name == dir do return fmt.tprintf("%s.%s", imp.base, name)
	}
	last_slash := strings.last_index_byte(dir, '/')
	return fmt.tprintf("%s.%s", dir[last_slash + 1:], name)
}

@(private = "file")
lint_unused_parameter :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_unused_parameter do return

	lit: ^ast.Proc_Lit
	#partial switch n in node.derived {
	case ^ast.Value_Decl:
		// Visited before its Proc_Lit child, so the attributes are known by then.
		if len(n.values) != 1 do return
		lit = n.values[0].derived.(^ast.Proc_Lit) or_else nil
		if lit == nil do return
		if has_fixed_signature_attribute(n.attributes[:]) {
			ctx.skip[lit] = {}
		} else if len(unused_params(lit)) > 0 && is_signature_fixed_by_use(ctx, n) {
			ctx.skip[lit] = {}
		}
		return
	case ^ast.Call_Expr:
		// The callee's parameter type fixes the signature of a procedure literal argument.
		for arg in n.args do skip_context_typed_proc(ctx, arg)
		return
	case ^ast.Comp_Lit:
		for elem in n.elems do skip_context_typed_proc(ctx, elem)
		return
	case ^ast.Assign_Stmt:
		for rhs in n.rhs do skip_context_typed_proc(ctx, rhs)
		return
	case ^ast.Proc_Lit:
		lit = n
	case:
		return
	}

	if node in ctx.skip do return
	for ident in unused_params(lit) {
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(ident, ctx.src),
				severity = .Hint,
				code = "unused-parameter",
				message = fmt.tprintf("parameter %s is unused", ident.name),
				tags = unnecessary_tags,
			},
		)
		// A call naming the argument stops compiling once the parameter is `_`. Calls in other files are
		// checked only by the quick fix (see add_lint_fix_action).
		if declares_one_name(lit, ident) && ident.name not_in lint_named_arguments(ctx) {
			append(
				&ctx.fixes,
				Lint_Fix{ident.pos.offset, ident.end.offset, "Rename parameter to `_`", "_", "unused-parameter"},
			)
		}
	}
}

// A procedure literal passed as an argument, stored in a composite literal or assigned takes its signature
// from the parameter, field or variable type.
@(private = "file")
skip_context_typed_proc :: proc(ctx: ^LintContext, expr: ^ast.Expr) {
	expr := expr
	if field_value, is_field_value := expr.derived.(^ast.Field_Value); is_field_value do expr = field_value.value
	if lit, is_lit := expr.derived.(^ast.Proc_Lit); is_lit do ctx.skip[lit] = {}
}

// A declaration with an explicit type (`h: Handler = proc(…) {…}`) takes its signature from that type. A named
// procedure that the same file uses as a value (an argument, an assignment, a composite literal element, a
// parameter default) has its signature fixed by the proc type it is stored in. A use in another file is not seen.
@(private = "file")
is_signature_fixed_by_use :: proc(ctx: ^LintContext, decl: ^ast.Value_Decl) -> bool {
	if decl.type != nil do return true
	if decl.is_mutable || len(decl.names) != 1 do return false
	name := decl.names[0].derived.(^ast.Ident) or_return
	return name.name in value_names(ctx)
}

// Every name the file mentions as a value, found in one walk. A mention counts when it resolves to a procedure
// or to nothing, so a same-named local variable does not hide an unused parameter.
@(private = "file")
value_names :: proc(ctx: ^LintContext) -> map[string]struct{} {
	names, has_names := ctx.value_names.?
	if has_names do return names

	names = make(map[string]struct{}, context.temp_allocator)
	symbols := lint_symbols(ctx)
	for stmt in ctx.document.ast.decls {
		for use in collect_ident_uses(stmt) {
			if !is_value_use(use) do continue
			if resolved, found := symbols[uintptr(use.ident)]; found && !resolved.is_unresolved {
				#partial switch _ in resolved.symbol.value {
				case SymbolProcedureValue, SymbolProcedureGroupValue:
				case:
					continue
				}
			}
			names[use.ident.name] = {}
		}
	}
	ctx.value_names = names
	return names
}

@(private = "file")
lint_named_arguments :: proc(ctx: ^LintContext) -> map[string]struct{} {
	names, has_names := ctx.named_args.?
	if !has_names {
		names = named_arguments(&ctx.document.ast)
		ctx.named_args = names
	}
	return names
}

// Every name a call in file gives an argument (`f(x, flag = true)` gives `flag`), whatever the callee.
named_arguments :: proc(file: ^ast.File) -> map[string]struct{} {
	names := make(map[string]struct{}, context.temp_allocator)
	for stmt in file.decls {
		for use in collect_ident_uses(stmt) {
			if len(use.parents) < 2 do continue
			field_value, is_field_value := use.parents[len(use.parents) - 1].derived.(^ast.Field_Value)
			if !is_field_value || field_value.field != use.ident do continue
			if call, is_call := use.parents[len(use.parents) - 2].derived.(^ast.Call_Expr); is_call {
				if slice.contains(call.args, (^ast.Expr)(field_value)) do names[use.ident.name] = {}
			}
		}
	}
	return names
}

// A mention that neither declares a name, calls it, nor names a field, parameter or group member.
@(private = "file")
is_value_use :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 do return false
	#partial switch parent in use.parents[len(use.parents) - 1].derived {
	case ^ast.Call_Expr:
		return parent.expr != use.ident
	case ^ast.Selector_Expr:
		return parent.field != use.ident
	case ^ast.Field_Value:
		return parent.field != use.ident
	case ^ast.Value_Decl:
		return !slice.contains(parent.names, (^ast.Expr)(use.ident))
	case ^ast.Field:
		return parent.default_value == (^ast.Expr)(use.ident)
	case ^ast.Proc_Group:
		return false
	}
	return true
}

// `a, b: int` would need every name renamed to stay valid, so only a lone name gets a fix.
@(private = "file")
declares_one_name :: proc(lit: ^ast.Proc_Lit, ident: ^ast.Ident) -> bool {
	for param in lit.type.params.list {
		for name in param.names {
			if n, is_ident := name.derived.(^ast.Ident); is_ident && n == ident do return len(param.names) == 1
		}
	}
	return false
}

// Parameters the body never reads. Skips foreign and non-Odin procedures, empty and panic-only
// bodies, `using` and `_` names, and names tied to a polymorphic type.
unused_params :: proc(lit: ^ast.Proc_Lit) -> []^ast.Ident {
	if lit.body == nil || lit.type == nil || lit.type.params == nil do return {}
	if convention, is_string := lit.type.calling_convention.(string); is_string {
		convention = strings.trim(convention, "\"`")
		if convention != "odin" && convention != "contextless" do return {}
	}
	body, is_block := lit.body.derived.(^ast.Block_Stmt)
	if !is_block do return {}
	if len(body.stmts) == 0 || (len(body.stmts) == 1 && is_panic_call(body.stmts[0])) do return {}

	poly_names := make(map[string]struct{}, context.temp_allocator)
	for param in lit.type.params.list {
		for name in param.names {
			if poly, ok := name.derived.(^ast.Poly_Type); ok do poly_names[poly.type.name] = {}
		}
		for use in collect_ident_uses(param.type) {
			if len(use.parents) > 0 {
				if _, ok := use.parents[len(use.parents) - 1].derived.(^ast.Poly_Type); ok do poly_names[use.ident.name] = {}
			}
		}
	}

	unused := make([dynamic]^ast.Ident, context.temp_allocator)
	uses := collect_ident_uses(lit.body)
	for param in lit.type.params.list {
		if .Using in param.flags do continue
		if mentions_poly(param.type, poly_names) do continue
		names: for name in param.names {
			ident := name.derived.(^ast.Ident) or_continue
			if strings.has_prefix(ident.name, "_") do continue
			for use in uses {
				if use.ident.name == ident.name && !is_field_name(use) do continue names
			}
			append(&unused, ident)
		}
	}
	return unused[:]
}

// The left side of `field = value` names a struct field or a parameter, not a variable.
@(private = "file")
is_field_name :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 do return false
	field_value, ok := use.parents[len(use.parents) - 1].derived.(^ast.Field_Value)
	return ok && field_value.field == use.ident
}

@(private = "file")
mentions_poly :: proc(type: ^ast.Expr, poly_names: map[string]struct{}) -> bool {
	if type == nil do return false
	for use in collect_ident_uses(type) {
		if use.ident.name in poly_names do return true
	}
	return false
}

has_fixed_signature_attribute :: proc(attributes: []^ast.Attribute) -> bool {
	for name in attribute_names(attributes) {
		if name == "export" || name == "link_name" || strings.has_prefix(name, "deferred_") do return true
	}
	return false
}

attribute_names :: proc(attributes: []^ast.Attribute) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for attribute in attributes {
		for elem in attribute.elems {
			#partial switch e in elem.derived {
			case ^ast.Ident:
				append(&names, e.name)
			case ^ast.Field_Value:
				field := e.field.derived.(^ast.Ident) or_continue
				append(&names, field.name)
			}
		}
	}
	return names[:]
}
