package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

import "src:common"

LintContext :: struct {
	document: ^Document,
	config:   ^common.Config,
	src:      string,
	symbols:  Maybe(SymbolAndNodeMap),
	// Nodes a lint excluded while visiting their parent: deferred statements and proc literals
	// whose signature an attribute on the declaring Value_Decl fixes.
	skip:     map[^ast.Node]struct{},
	fixes:    [dynamic]Lint_Fix,
}

// A single-edit fix for one diagnostic, offered as a quick fix at the cursor.
Lint_Fix :: struct {
	start, end:  int,
	title, text: string,
}

lint_symbols :: proc(ctx: ^LintContext) -> SymbolAndNodeMap {
	symbols, has_symbols := ctx.symbols.?
	if !has_symbols {
		symbols = resolve_entire_file(ctx.document)
		ctx.symbols = symbols
	}
	return symbols
}

@(private = "file")
lints := [?]proc(_: ^LintContext, _: ^ast.Node, _: ^[dynamic]Diagnostic) {
	lint_self_assignment,
	lint_identical_branches,
	lint_unreachable_code,
	lint_float_equality,
	lint_printf,
	lint_ignored_result,
	lint_unused_parameter,
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
}

@(private = "file")
Walker :: struct {
	ctx:   LintContext,
	diags: [dynamic]Diagnostic,
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
	visitor := ast.Visitor {
		data = &w,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			w := (^Walker)(visitor.data)
			for lint in lints {
				lint(&w.ctx, node, &w.diags)
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
					tags = {.Unnecessary},
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
		append(&ctx.fixes, Lint_Fix{start, end, "Remove self-assignment", ""})
	}

	for i in 0 ..< min(len(assign.lhs), len(assign.rhs)) {
		if contains_call(assign.rhs[i]) do continue
		lhs := strip_space(node_text(ctx.src, assign.lhs[i]))
		if lhs != strip_space(node_text(ctx.src, assign.rhs[i])) do continue
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
		range := common.get_token_range(stmts[i + 1], ctx.src)
		range.end = common.get_token_range(stmts[len(stmts) - 1], ctx.src).end
		append(
			diags,
			Diagnostic {
				range = range,
				severity = .Hint,
				code = "unreachable-code",
				message = "unreachable code",
				tags = {.Unnecessary},
			},
		)
		start, end := whole_lines(ctx.src, stmts[i + 1].pos.offset, stmts[len(stmts) - 1].end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove unreachable code", ""})
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

	results := value.return_types
	// Either tag makes only the last result optional.
	if len(results) > 0 &&
	   len(results[len(results) - 1].names) <= 1 &&
	   (.Optional_Ok in value.tags || .Optional_Allocator_Error in value.tags) {
		results = results[:len(results) - 1]
	}

	for field in results {
		name := must_handle_type_name(field.type) or_continue
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

// bool, unions and anything named like an error must be handled by the caller,
// except Allocator_Error, which delete/free/reserve callers ignore as a matter of course.
@(private = "file")
must_handle_type_name :: proc(type: ^ast.Expr) -> (string, bool) {
	if type == nil do return "", false
	#partial switch t in type.derived {
	case ^ast.Ident:
		if t.name == "Allocator_Error" do return "", false
		if t.name == "bool" || strings.contains(t.name, "Err") do return t.name, true
	case ^ast.Selector_Expr:
		if t.field == nil || t.field.name == "Allocator_Error" || !strings.contains(t.field.name, "Err") do return "", false
		if pkg, ok := t.expr.derived.(^ast.Ident); ok do return fmt.tprintf("%s.%s", pkg.name, t.field.name), true
		return t.field.name, true
	case ^ast.Union_Type:
		return "union", true
	}
	return "", false
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
		}
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
				tags = {.Unnecessary},
			},
		)
		if declares_one_name(lit, ident) {
			append(&ctx.fixes, Lint_Fix{ident.pos.offset, ident.end.offset, "Rename parameter to `_`", "_"})
		}
	}
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
