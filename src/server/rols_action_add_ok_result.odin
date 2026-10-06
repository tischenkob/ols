#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

@(private = "package")
add_add_ok_result_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_add_ok_result {
		return
	}

	decl: ^ast.Value_Decl
	lit: ^ast.Proc_Lit
	for at in nodes_at(ctx.document.ast.decls[:], ctx.range.start) {
		d, is_decl := at.node.derived.(^ast.Value_Decl)
		if !is_decl || len(d.values) != 1 {
			continue
		}
		if l, is_lit := d.values[0].derived.(^ast.Proc_Lit); is_lit {
			decl, lit = d, l
		}
	}
	if lit == nil || lit.type == nil || lit.body == nil {
		return
	}
	// Both tags require exactly two results, so a third one would not compile.
	if lit.type.tags & {.Optional_Ok, .Optional_Allocator_Error} != {} {
		return
	}

	pos := ctx.range.start
	results := lit.type.results
	on_target := results != nil && results.pos.offset <= pos && pos <= results.end.offset
	for name in decl.names {
		on_target ||= name.pos.offset <= pos && pos <= name.end.offset
	}
	if !on_target {
		return
	}
	types: []^ast.Expr
	if results != nil {
		// An empty `-> ()` has no result to extend and no spot for ` -> bool`.
		if len(results.list) == 0 {
			return
		}
		types = field_types(results.list)
	}
	// A last bool result is already the ok flag, and a second one would only shadow it.
	if len(types) > 0 && result_kind_in(ctx.document, ctx.document.package_name, types[len(types) - 1]) == .Bool {
		return
	}

	// or_return assigns its operand's end value to the last result, which would become the bool.
	if has_or_return(lit.body) {
		return
	}

	old_count := len(types)
	changes := make(Changes, context.temp_allocator)
	if !add_ok_to_callers(ctx, &changes, decl, lit, old_count) {
		return
	}

	src := ctx.document.ast.src
	edits := changes[ctx.document.uri.uri] or_else make([dynamic]TextEdit, context.temp_allocator)

	if results == nil {
		// Before the body brace rather than at the proc type end, which a where clause extends.
		at := lit.body.pos.offset
		for at > 0 && strings.is_space(rune(src[at - 1])) {
			at -= 1
		}
		append(&edits, TextEdit{range = range_of(ctx, at, at), newText = " -> bool"})

		// Falling off the end is the success path, and a bool result makes it a missing return.
		block := lit.body.derived_stmt.(^ast.Block_Stmt)
		ends_in_return := false
		if n := len(block.stmts); n > 0 {
			_, ends_in_return = block.stmts[n - 1].derived_stmt.(^ast.Return_Stmt)
		}
		if !ends_in_return {
			ind := get_line_indentation(src, decl.pos.offset)
			first: ^ast.Stmt
			if len(block.stmts) > 0 {
				first = block.stmts[0]
			}
			close := block.close.offset
			for close > 0 && strings.is_space(rune(src[close - 1])) {
				close -= 1
			}
			text := fmt.tprintf("\n%s%sreturn true", ind, indent_unit(src, ind, first))
			append(&edits, TextEdit{range = range_of(ctx, close, close), newText = text})
		}
	} else {
		named := results_named(results)
		taken := make([dynamic]string, context.temp_allocator)
		if lit.type.params != nil {
			for field in lit.type.params.list {
				for name in field.names {
					append(&taken, final_name(name))
				}
			}
		}
		if named {
			for field in results.list {
				for name in field.names {
					append(&taken, final_name(name))
				}
			}
		}

		// Only insertions, so comments and line breaks in the list stay as written.
		text := ", bool"
		if named {
			ok := "ok"
			for i := 2; slice.contains(taken[:], ok); i += 1 {
				ok = fmt.tprintf("ok%d", i)
			}
			text = fmt.tprintf(", %s: bool", ok)
		}
		// Only an unparenthesized result has no names; the list node excludes parentheses.
		if results.list[0].names == nil {
			start, end := results.pos.offset, results.end.offset
			append(&edits, TextEdit{range = range_of(ctx, start, start), newText = "("})
			close := strings.concatenate({text, ")"}, context.temp_allocator)
			append(&edits, TextEdit{range = range_of(ctx, end, end), newText = close})
		} else {
			end := results.list[len(results.list) - 1].end.offset
			append(&edits, TextEdit{range = range_of(ctx, end, end), newText = text})
		}
	}

	for ret in body_returns(lit.body) {
		if len(ret.results) == 0 {
			// A bare return still works once every result is named.
			if results != nil {
				continue
			}
			append(&edits, TextEdit{range = range_of(ctx, ret.end.offset, ret.end.offset), newText = " true"})
		} else {
			append(&edits, TextEdit{range = range_of(ctx, ret.end.offset, ret.end.offset), newText = ", true"})
		}
	}

	changes[ctx.document.uri.uri] = edits
	append(ctx.actions, CodeAction{title = "Add ok result", kind = "refactor.rewrite", edit = workspace_edit(changes)})
}

// Whether the result list names its results. The parser gives an unnamed result a synthesised
// name at the type's own position, so counting names would read `(int, bool)` as named.
results_named :: proc(results: ^ast.Field_List) -> bool {
	for field in results.list {
		for name in field.names {
			if field.type == nil || name.pos.offset != field.type.pos.offset {
				return true
			}
		}
	}
	return false
}

has_or_return :: proc(body: ^ast.Stmt) -> bool {
	found := false
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch _ in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Or_Return_Expr:
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return found
}

// Adds `, _` to every call that receives the old results, so each caller still compiles. A
// call in any other position, and a procedure whose callers cannot all be found, refuse the action.
add_ok_to_callers :: proc(
	ctx: ^ActionContext,
	changes: ^Changes,
	decl: ^ast.Value_Decl,
	lit: ^ast.Proc_Lit,
	old_count: int,
) -> bool {
	// A new unused result breaks a call of a @(require_results) procedure.
	if old_count == 0 && slice.contains(attribute_names(decl.attributes[:]), "require_results") {
		return false
	}
	if has_fixed_signature_attribute(decl.attributes[:]) {
		return false
	}
	if _, is_top := proc_decl_of(ctx.document, lit); !is_top {
		// A local procedure's callers are not searched for, so it must have none. Only the top-level
		// declaration that holds it can name it.
		name := final_name(decl.names[0])
		for top in ctx.document.ast.decls {
			if decl.pos.offset < top.pos.offset || top.end.offset < decl.end.offset {
				continue
			}
			for use in collect_ident_uses(top) {
				if use.ident.name == name && use.ident.pos.offset != decl.names[0].pos.offset {
					return false
				}
			}
		}
		return true
	}
	// The action edits one declaration, so the targets that build a platform variant would break.
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	if len(top_level_variants(&h, ctx.document, decl)) > 0 {
		return false
	}
	// Only the left side of each call changes, so named, defaulted and spread arguments do not matter.
	sites := make([dynamic]Call_Site, context.temp_allocator)
	h.documents[ctx.document.uri.uri] = ctx.document
	for location in proc_references(ctx.document, decl, ctx.files) {
		caller := hierarchy_document(&h, location.uri)
		if caller == nil {
			return false
		}
		call, ok := call_at_reference(caller, location)
		if !ok || call == nil {
			return false
		}
		append(&sites, Call_Site{caller, call})
	}
	for site in sites {
		parent: ^ast.Node
		for at in nodes_at(site.document.ast.decls[:], site.call.pos.offset) {
			if at.node == site.call {
				parent = at.parent
			}
		}
		if parent == nil {
			return false
		}
		last: ^ast.Expr
		#partial switch p in parent.derived {
		case ^ast.Expr_Stmt:
			continue
		case ^ast.Value_Decl:
			single := len(p.values) == 1 && p.values[0] == site.call
			if !p.is_mutable || p.type != nil || !single || len(p.names) != old_count {
				return false
			}
			last = p.names[old_count - 1]
		case ^ast.Assign_Stmt:
			if p.op.kind != .Eq || len(p.rhs) != 1 || p.rhs[0] != site.call || len(p.lhs) != old_count {
				return false
			}
			last = p.lhs[old_count - 1]
		case:
			return false
		}
		append_edit(changes, site.document, last.end.offset, last.end.offset, ", _")
	}
	return true
}

// Returns of this procedure, skipping those of nested procedure literals.
@(private = "package")
body_returns :: proc(body: ^ast.Stmt) -> []^ast.Return_Stmt {
	found := make([dynamic]^ast.Return_Stmt, context.temp_allocator)
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt:
				append((^[dynamic]^ast.Return_Stmt)(visitor.data), n)
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return found[:]
}
