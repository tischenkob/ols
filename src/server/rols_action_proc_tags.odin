#+private file

package server

import "core:odin/ast"
import "core:slice"
import "core:strings"

import "src:common"

// On the name of a top-level procedure with a body: add or remove `#force_inline`, `#force_no_inline` and
// `"contextless"`, where the result compiles.
@(private = "package")
add_proc_tags_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_proc_tags {
		return
	}
	decl, found := top_decl_at(ctx.document, ctx.range.start)
	if !found || decl.is_mutable || decl.type != nil || len(decl.values) != 1 {
		return
	}
	lit, is_proc := decl.values[0].derived.(^ast.Proc_Lit)
	if !is_proc || lit.body == nil || lit.type == nil || has_fixed_signature_attribute(decl.attributes[:]) {
		return
	}
	// Each platform variant would need the same tag.
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	if len(top_level_variants(&h, ctx.document, decl)) > 0 {
		return
	}
	add_inline_tags(ctx, decl, lit)
	add_contextless_tag(ctx, decl, lit)
}

add_inline_tags :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl, lit: ^ast.Proc_Lit) {
	src := ctx.document.ast.src
	keyword := lit.type.tok.pos.offset
	head := decl.names[0].end.offset
	switch lit.inlining {
	case .None:
		// The compiler cannot inline a procedure into itself.
		if !calls_itself(lit, final_name(decl.names[0])) {
			append_insert(ctx, keyword, "Add #force_inline", "refactor.rewrite", "#force_inline ")
		}
		append_insert(ctx, keyword, "Add #force_no_inline", "refactor.rewrite", "#force_no_inline ")
	case .Inline, .No_Inline:
		tag := "#force_inline" if lit.inlining == .Inline else "#force_no_inline"
		at := strings.index(src[head:keyword], tag)
		if at < 0 {
			return
		}
		start := head + at
		end := start + len(tag)
		for end < keyword && strings.is_space(rune(src[end])) {
			end += 1
		}
		append_replace_range(ctx, start, end, strings.concatenate({"Remove ", tag}, context.temp_allocator), "")
	}
}

add_contextless_tag :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl, lit: ^ast.Proc_Lit) {
	type := lit.type
	if type.params == nil {
		return
	}
	src := ctx.document.ast.src
	after := type.tok.pos.offset + len(type.tok.text)
	convention, has_convention := type.calling_convention.(string)
	if type.calling_convention == nil {
		if names_context(lit) || !calls_only_contextless(ctx, lit) || !references_allow(ctx, decl, false) {
			return
		}
		text := " \"contextless\" " if src[after] == '(' else " \"contextless\""
		append_insert(ctx, after, "Add \"contextless\"", "refactor.rewrite", text)
	} else if has_convention && strings.trim(convention, "\"") == "contextless" {
		// A call from a contextless procedure would then need a context it does not have.
		if !references_allow(ctx, decl, true) {
			return
		}
		at := strings.index(src[after:type.params.pos.offset], "\"contextless\"")
		if at < 0 {
			return
		}
		end := after + at + len("\"contextless\"")
		for end < type.params.pos.offset && strings.is_space(rune(src[end])) {
			end += 1
		}
		append_replace_range(ctx, after, end, "Remove \"contextless\"", "")
	}
}

// Whether the procedure body calls the procedure by its name, outside a nested procedure literal.
calls_itself :: proc(lit: ^ast.Proc_Lit, name: string) -> bool {
	for call in body_calls(lit) {
		if callee, is_ident := ast.unparen_expr(call.expr).derived.(^ast.Ident); is_ident && callee.name == name {
			return true
		}
	}
	return false
}

// The calls of the procedure header and body, outside nested procedure literals, which have a context of their own.
body_calls :: proc(lit: ^ast.Proc_Lit) -> []^ast.Call_Expr {
	Data :: struct {
		root:  ^ast.Proc_Lit,
		calls: [dynamic]^ast.Call_Expr,
	}
	data := Data{lit, make([dynamic]^ast.Call_Expr, context.temp_allocator)}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				if n != data.root {
					return nil
				}
			case ^ast.Call_Expr:
				append(&data.calls, n)
			}
			return visitor
		},
	}
	ast.walk(&visitor, lit)
	return data.calls[:]
}

// Whether the header or body reads `context`, outside nested procedure literals.
names_context :: proc(lit: ^ast.Proc_Lit) -> bool {
	Data :: struct {
		root:  ^ast.Proc_Lit,
		found: bool,
	}
	data := Data{lit, false}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				if n != data.root {
					return nil
				}
			case ^ast.Implicit:
				data.found ||= n.tok.kind == .Context
			case ^ast.Comp_Lit:
				// A dynamic array or map literal allocates with the context allocator.
				if n.type != nil {
					#partial switch _ in n.type.derived {
					case ^ast.Dynamic_Array_Type, ^ast.Map_Type:
						data.found = true
					}
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, lit)
	return data.found
}

// The compiler's own procedures, which need no context.
CONTEXTLESS_BUILTINS :: []string {
	"len",
	"cap",
	"size_of",
	"align_of",
	"offset_of",
	"type_of",
	"typeid_of",
	"min",
	"max",
	"abs",
	"clamp",
	"swizzle",
	"complex",
	"quaternion",
	"real",
	"imag",
	"jmag",
	"kmag",
	"conj",
	"card",
}

// Calling conventions that pass no context.
NO_CONTEXT_CONVENTIONS :: []string{"contextless", "c", "cdecl", "system", "std", "stdcall", "fastcall", "none"}

// Whether every call in the procedure is a type conversion, a builtin without context, or a call of a procedure whose
// calling convention passes no context. A group, an unresolved callee and an `->` call count as needing a context.
calls_only_contextless :: proc(ctx: ^ActionContext, lit: ^ast.Proc_Lit) -> bool {
	defer restore_locals(ctx)
	for call in body_calls(lit) {
		if selector, is_selector := call.expr.derived.(^ast.Selector_Expr);
		   is_selector && selector.op.kind == .Arrow_Right {
			return false
		}
		gather_locals_in(ctx, lit, call.pos.offset)
		ctx.ast_context.use_locals = true
		symbol, resolved := resolve_type_expression(ctx.ast_context, call.expr)
		if !resolved {
			return false
		}
		if symbol.pkg == "$builtin" {
			callee, is_ident := call.expr.derived.(^ast.Ident)
			if !is_ident || !slice.contains(CONTEXTLESS_BUILTINS, callee.name) {
				return false
			}
			continue
		}
		#partial switch v in symbol.value {
		case SymbolProcedureValue:
			convention, is_string := v.calling_convention.(string)
			if !is_string || !slice.contains(NO_CONTEXT_CONVENTIONS, strings.trim(convention, "\"")) {
				return false
			}
		case SymbolProcedureGroupValue, SymbolAggregateValue:
			return false
		case:
			// A conversion names a type, never a variable.
			if .Mutable in symbol.flags || symbol.type == .Variable || symbol.type == .Function {
				return false
			}
		}
	}
	return true
}

// Whether every reference to the procedure is a call, since a procedure value takes the calling convention into its
// type, and, when from_contextless, no call lies in a contextless procedure.
references_allow :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl, from_contextless: bool) -> bool {
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.uri] = ctx.document
	for location in proc_references(ctx.document, decl, ctx.files) {
		caller := hierarchy_document(&h, location.uri)
		if caller == nil {
			return false
		}
		call, ok := call_at_reference(caller, location)
		if !ok || call == nil {
			return false
		}
		if !from_contextless {
			continue
		}
		offset, offset_ok := common.get_absolute_position(location.range.start, caller.text[:caller.used_text])
		if !offset_ok {
			return false
		}
		for at in nodes_at(caller.ast.decls[:], offset) {
			enclosing, is_lit := at.node.derived.(^ast.Proc_Lit)
			if !is_lit || enclosing.type == nil {
				continue
			}
			if convention, is_string := enclosing.type.calling_convention.(string);
			   is_string && strings.trim(convention, "\"") == "contextless" {
				return false
			}
		}
	}
	return true
}
