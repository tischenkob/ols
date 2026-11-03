#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

// `a.b.x` and `a.b.y` become `x` and `y` under a new `using a.b` before the first use in the block.
// A `using` statement evaluates nothing: the compiler rebuilds the path at each use of a field, so
// the statement can move past reassignments of the path and above conditional uses.
@(private = "package")
add_lift_using_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_lift_using {
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	src := ctx.document.ast.src
	start, end := trim_range(src, ctx.range.start, ctx.range.end)

	list, found := find_stmt_list_at(function.body, start, end)
	if !found || list.first != list.last {
		return
	}
	if in_when_body(function.body, start) {
		return
	}
	stmt := list.stmts[list.first]
	if stmt.pos.offset > start || end > stmt.end.offset {
		return
	}

	paths := find_paths(stmt, start, end)
	if len(paths) == 0 {
		return
	}

	typed := resolve_entire_file(ctx.document)
	// The whole-file reference pass waits for a path that can be lifted: a cursor on a callee or type name has none.
	symbols: SymbolAndNodeMap
	have_symbols := false

	count := 0
	for path in paths {
		if count == MAX_EXTRACT_WIDTHS {
			break
		}
		fields, liftable := using_fields(ctx, typed, path)
		if !liftable {
			continue
		}
		if !have_symbols {
			symbols = resolve_entire_file_for_references(ctx.document, context.temp_allocator, .Identifier, "")
			have_symbols = true
		}
		if edits, ok := lift_edits(ctx, symbols, fields, list.stmts, list.first, path); ok {
			title := fmt.tprintf("Lift using %s", strip_space(node_text(src, path)))
			append(ctx.actions, make_code_action(ctx, title, "refactor.rewrite", edits))
			count += 1
		}
	}
}

// A `when` opens no scope, so a `using` in its body would leak into the enclosing block.
in_when_body :: proc(body: ^ast.Stmt, pos: int) -> bool {
	nodes := nodes_at({body}, pos)
	#reverse for at in nodes {
		#partial switch _ in at.node.derived {
		case ^ast.Block_Stmt, ^ast.Case_Clause:
			if at.parent == nil {
				return false
			}
			_, is_when := at.parent.derived.(^ast.When_Stmt)
			return is_when
		}
	}
	return false
}

// The identifier at the root of a chain of `.` selectors, nil for any other expression.
path_root :: proc(expr: ^ast.Expr) -> ^ast.Ident {
	#partial switch e in expr.derived {
	case ^ast.Ident:
		return e
	case ^ast.Selector_Expr:
		if e.op.kind == .Period && e.field != nil {
			return path_root(e.expr)
		}
	}
	return nil
}

same_path :: proc(a, b: ^ast.Expr) -> bool {
	#partial switch x in a.derived {
	case ^ast.Ident:
		y, ok := b.derived.(^ast.Ident)
		return ok && x.name == y.name
	case ^ast.Selector_Expr:
		y, ok := b.derived.(^ast.Selector_Expr)
		return ok && x.field.name == y.field.name && same_path(x.expr, y.expr)
	}
	return false
}

// The selected path (exact match), or the paths under the cursor, innermost first. On the field of
// a selector, its base comes first: `x` in `a.b.x` is usually not a struct itself.
find_paths :: proc(stmt: ^ast.Stmt, start, end: int) -> []^ast.Expr {
	found := make([dynamic]^ast.Expr, context.temp_allocator)
	nodes := nodes_at({stmt}, start)
	#reverse for at in nodes {
		expr := cast(^ast.Expr)at.node
		if path_root(expr) == nil {
			continue
		}
		if at.parent != nil {
			if parent, ok := at.parent.derived.(^ast.Selector_Expr); ok && parent.field == at.node {
				if start == end && path_root(parent.expr) != nil {
					append(&found, parent.expr)
				}
				continue
			}
		}
		if start == end || (expr.pos.offset == start && expr.end.offset == end) {
			append(&found, expr)
		}
	}
	return found[:]
}

// The field names `using` brings into scope, for a variable of struct or single pointer to struct type.
using_fields :: proc(
	ctx: ^ActionContext,
	typed: SymbolAndNodeMap,
	path: ^ast.Expr,
) -> (
	fields: map[string]struct{},
	ok: bool,
) {
	resolved, present := typed[uintptr(path_root(path))]
	if !present || (.Mutable not_in resolved.symbol.flags && .Parameter not_in resolved.symbol.flags) {
		return
	}
	// An earlier resolution can leave use_locals off, and the root is usually a local.
	reset_ast_context(ctx.ast_context)
	symbol := resolve_type_expression(ctx.ast_context, path) or_return
	value := symbol.value.(SymbolStructValue) or_return
	if symbol.pointers > 1 {
		return
	}
	// expand_usings skips a `using` field whose type it cannot resolve, and that field's names would be missing.
	for u in value.usings {
		type := value.types[u]
		set_ast_package_set_scoped(ctx.ast_context, get_package_from_node(type.expr_base))
		reset_ast_context(ctx.ast_context)
		embedded := resolve_type_expression(ctx.ast_context, type) or_return
		#partial switch _ in embedded.value {
		case SymbolStructValue, SymbolBitFieldValue:
		case:
			return
		}
	}

	fields = make(map[string]struct{}, context.temp_allocator)
	for name in value.names {
		if name != "_" {
			fields[name] = {}
		}
	}
	return fields, true
}

lift_edits :: proc(
	ctx: ^ActionContext,
	symbols: SymbolAndNodeMap,
	fields: map[string]struct{},
	stmts: []^ast.Stmt,
	cursor_stmt: int,
	path: ^ast.Expr,
) -> (
	edits: []TextEdit,
	ok: bool,
) {
	src := ctx.document.ast.src
	root := path_root(path)
	root_decl, root_local := local_decl_offset(ctx, symbols, root)

	edit_list := make([dynamic]TextEdit, context.temp_allocator)
	rewritten := make(map[^ast.Ident]struct{}, context.temp_allocator)
	first := -1
	for stmt, i in stmts {
		if stmt == nil {
			continue
		}
		uses := collect_ident_uses(stmt)
		for use in uses {
			if use.ident.name != root.name || is_member_name(use) {
				continue
			}
			decl, local := local_decl_offset(ctx, symbols, use.ident)
			if local != root_local || local && decl != root_decl {
				continue
			}
			selector := selector_on_path(use, path)
			if selector == nil {
				continue
			}
			if selector.field.name not_in fields || in_offset_of(use) {
				return
			}
			if first < 0 {
				first = i
			}
			rewritten[use.ident] = {}
			append(&edit_list, TextEdit{range = range_of(ctx, selector.pos.offset, selector.field.pos.offset)})
		}
	}
	if first < 0 {
		return
	}
	anchor := stmts[first]
	// A root declared in the header of the first statement, as in `if a := get(); a.x > 0`, is not in
	// scope above that statement.
	if root_local && root_decl >= anchor.pos.offset {
		return
	}

	// Every field enters scope: a name in the range would change meaning or collide, and a name in
	// the same scope collides whatever its position. Another `using` in the range brings in names
	// that appear nowhere as identifiers, and it can capture a rewritten use or collide. The scan
	// starts at the cursor when that is earlier, because the locals below stop at the cursor.
	for stmt in stmts[min(first, cursor_stmt):] {
		if stmt == nil {
			continue
		}
		for use in collect_ident_uses(stmt) {
			if under_using(use) {
				return
			}
			if use.ident in rewritten || (is_member_name(use) && !is_index_key(ctx, use)) {
				continue
			}
			if use.ident.name in fields {
				return
			}
		}
	}
	for name in fields {
		probe: ast.Ident
		probe.pos = anchor.pos
		probe.name = name
		if _, taken := get_local(ctx.ast_context^, probe); taken {
			return
		}
	}

	line_start, _ := before_on_line(src, anchor.pos.offset)
	indent := src[line_start:anchor.pos.offset]
	if strings.trim_space(indent) != "" || has_prefix_above(src, anchor, line_start) {
		return
	}
	append(
		&edit_list,
		TextEdit {
			range = range_of(ctx, line_start, line_start),
			newText = strings.concatenate(
				{indent, "using ", strip_space(node_text(src, path)), "\n"},
				context.temp_allocator,
			),
		},
	)
	if !file_has_feature(ctx.document, "using-stmt") {
		at := file_tag_offset(ctx.document, src)
		append(&edit_list, TextEdit{range = range_of(ctx, at, at), newText = "#+feature using-stmt\n"})
	}
	return edit_list[:], true
}

// `offset_of(a.b.x)` needs a selector, so `offset_of(x)` does not compile.
in_offset_of :: proc(use: IdentUse) -> bool {
	for parent in use.parents {
		call, is_call := parent.derived.(^ast.Call_Expr)
		if !is_call {
			continue
		}
		name: string
		#partial switch callee in call.expr.derived {
		case ^ast.Ident:
			name = callee.name
		case ^ast.Selector_Expr:
			name = callee.field.name
		}
		if name == "offset_of" || name == "offset_of_selector" {
			return true
		}
	}
	return false
}

under_using :: proc(use: IdentUse) -> bool {
	for parent in use.parents {
		#partial switch p in parent.derived {
		case ^ast.Using_Stmt:
			return true
		case ^ast.Value_Decl:
			if p.is_using {
				return true
			}
		}
	}
	return false
}

// Whether the key of a Field_Value is an expression, which a field would capture. That holds in an
// array, enumerated array or map literal. A literal without a type counts too, because telling those
// apart needs the type from its context.
is_index_key :: proc(ctx: ^ActionContext, use: IdentUse) -> bool {
	count := len(use.parents)
	if count < 2 {
		return false
	}
	if _, is_key := use.parents[count - 1].derived.(^ast.Field_Value); !is_key {
		return false
	}
	lit, is_lit := use.parents[count - 2].derived.(^ast.Comp_Lit)
	if !is_lit {
		return false
	}
	if lit.type == nil {
		return true
	}
	reset_ast_context(ctx.ast_context)
	symbol, resolved := resolve_type_expression(ctx.ast_context, lit.type)
	if !resolved {
		return true
	}
	#partial switch _ in symbol.value {
	case SymbolStructValue, SymbolBitFieldValue:
		return false
	}
	return true
}

// A label, attribute or directive on the lines above a statement applies to the next statement, so a
// line inserted between them breaks it. The statement's position excludes them.
has_prefix_above :: proc(src: string, stmt: ^ast.Stmt, line_start: int) -> bool {
	#partial switch s in stmt.derived {
	case ^ast.Block_Stmt:
		if s.label != nil do return true
	case ^ast.If_Stmt:
		if s.label != nil do return true
	case ^ast.For_Stmt:
		if s.label != nil do return true
	case ^ast.Range_Stmt:
		if s.label != nil do return true
	case ^ast.Unroll_Range_Stmt:
		if s.label != nil do return true
	case ^ast.Switch_Stmt:
		if s.label != nil do return true
	case ^ast.Type_Switch_Stmt:
		if s.label != nil do return true
	case ^ast.Value_Decl:
		if len(s.attributes) > 0 do return true
	}
	before := strings.trim_right_space(src[:line_start])
	above := strings.trim_left_space(before[strings.last_index_byte(before, '\n') + 1:])
	return strings.has_prefix(above, "#") || strings.has_prefix(above, "@")
}

// The selector `path.field` that use is the root of, nil when use is not on the path or sits in a
// nested procedure, which sees no local `using`.
selector_on_path :: proc(use: IdentUse, path: ^ast.Expr) -> ^ast.Selector_Expr {
	for parent in use.parents {
		if _, is_proc := parent.derived.(^ast.Proc_Lit); is_proc {
			return nil
		}
	}
	node: ^ast.Expr = use.ident
	#reverse for parent in use.parents {
		selector, is_selector := parent.derived.(^ast.Selector_Expr)
		if !is_selector || selector.expr != node || selector.op.kind != .Period {
			return nil
		}
		if same_path(node, path) {
			return selector
		}
		node = selector
	}
	return nil
}
