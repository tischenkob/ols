package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"

import "src:common"

LintContext :: struct {
	document: ^Document,
	config:   ^common.Config,
	src:      string,
	symbols:  Maybe(SymbolAndNodeMap),
}

@(private = "file")
lints := [?]proc(_: ^LintContext, _: ^ast.Node, _: ^[dynamic]Diagnostic) {
	lint_self_assignment,
	lint_identical_branches,
	lint_unreachable_code,
	lint_float_equality,
}

// One AST walk; every lint sees every node and checks its own config key.
lint_document :: proc(document: ^Document, config: ^common.Config) -> []Diagnostic {
	Walker :: struct {
		ctx:   LintContext,
		diags: [dynamic]Diagnostic,
	}
	w := Walker {
		ctx = {document = document, config = config, src = string(document.text[:document.used_text])},
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
		return
	}
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
		call := s.expr.derived.(^ast.Call_Expr) or_return
		callee := call.expr.derived.(^ast.Ident) or_return
		return callee.name == "panic" || callee.name == "unreachable"
	}
	return false
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
@(private = "file")
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
		symbols, has_symbols := ctx.symbols.?
		if !has_symbols {
			symbols = resolve_entire_file(ctx.document)
			ctx.symbols = symbols
		}
		resolved := symbols[uintptr(expr)] or_return
		#partial switch v in resolved.symbol.value {
		case SymbolBasicValue:
			return slice.contains(untyped_map[.Float], v.ident.name)
		case SymbolUntypedValue:
			return v.type == .Float
		}
	}
	return false
}
