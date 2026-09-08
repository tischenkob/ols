package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

import "src:common"

lint_allocator :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_allocator do return

	lit := node.derived.(^ast.Proc_Lit) or_else nil
	if lit == nil || lit.body == nil do return

	// Uses inside a nested proc literal belong to that literal's own visit.
	uses := make([dynamic]IdentUse, context.temp_allocator)
	for use in collect_ident_uses(lit.body) {
		nested := false
		for parent in use.parents {
			if _, is_lit := parent.derived.(^ast.Proc_Lit); is_lit {
				nested = true
				break
			}
		}
		if !nested do append(&uses, use)
	}

	allocator_mismatch(ctx, uses[:], diags)
	make_len_append(ctx, uses[:], diags)
}

@(private = "file")
Alloc :: struct {
	name:      string,
	allocator: string,
	offset:    int,
}

@(private = "file")
allocator_mismatch :: proc(ctx: ^LintContext, uses: []IdentUse, diags: ^[dynamic]Diagnostic) {
	allocs := make([dynamic]Alloc, context.temp_allocator)

	for use in uses {
		call, callee := called(use)
		if call == nil do continue

		if allocates(callee) {
			arg, has_allocator := allocator_arg(ctx.src, call)
			if !has_allocator do continue
			name, has_name := assigned_name(use.parents, call)
			if !has_name do continue
			append(&allocs, Alloc{name, strip_space(node_text(ctx.src, arg)), call.pos.offset})
			continue
		}

		if !frees(callee) || len(call.args) == 0 do continue
		target := call.args[0].derived.(^ast.Ident) or_else nil
		if target == nil do continue
		alloc, allocated := last_alloc(allocs[:], target.name, call.pos.offset)
		if !allocated || alloc.allocator == "context.allocator" do continue

		arg, has_allocator := free_allocator(ctx.src, call)
		if has_allocator && strip_space(node_text(ctx.src, arg)) == alloc.allocator do continue

		append(
			diags,
			Diagnostic {
				range = common.get_token_range(call, ctx.src),
				severity = .Warning,
				code = "allocator-mismatch",
				message = fmt.tprintf(
					"'%s' was allocated with %s but freed with the context allocator",
					target.name,
					alloc.allocator,
				),
			},
		)

		start, end, text := call.close.offset, call.close.offset, fmt.tprintf(", %s", alloc.allocator)
		if has_allocator {
			start, end, text = arg.pos.offset, arg.end.offset, alloc.allocator
		}
		append(&ctx.fixes, Lint_Fix{start, end, fmt.tprintf("Free with %s", alloc.allocator), text})
	}
}

@(private = "file")
make_len_append :: proc(ctx: ^LintContext, uses: []IdentUse, diags: ^[dynamic]Diagnostic) {
	for use, i in uses {
		if len(use.parents) == 0 do continue
		decl := use.parents[len(use.parents) - 1].derived.(^ast.Value_Decl) or_else nil
		if decl == nil || !decl.is_mutable || len(decl.names) != 1 || len(decl.values) != 1 do continue
		if (decl.names[0].derived.(^ast.Ident) or_else nil) != use.ident do continue

		call := decl.values[0].derived.(^ast.Call_Expr) or_else nil
		if call == nil || len(call.args) != 2 do continue
		callee := call.expr.derived.(^ast.Ident) or_else nil
		if callee == nil || callee.name != "make" do continue
		if _, is_dynamic := call.args[0].derived.(^ast.Dynamic_Array_Type); !is_dynamic do continue

		// The second argument is a length only when it is a number or len(); otherwise it is the allocator.
		length := call.args[1]
		if lit, is_lit := length.derived.(^ast.Basic_Lit); is_lit {
			if lit.tok.text == "0" do continue
		} else if len_call, is_call := length.derived.(^ast.Call_Expr); !is_call ||
		   (len_call.expr.derived.(^ast.Ident) or_else nil) == nil ||
		   len_call.expr.derived.(^ast.Ident).name != "len" {
			continue
		}
		if !grown_by_append(uses[i + 1:], use.ident.name) do continue

		text := strip_space(node_text(ctx.src, length))
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(call, ctx.src),
				severity = .Warning,
				code = "make-len-append",
				message = fmt.tprintf(
					"'%s' starts with %s elements and append adds after them; use make([dynamic]T, 0, %s) for capacity",
					use.ident.name,
					text,
					text,
				),
			},
		)
		append(
			&ctx.fixes,
			Lint_Fix {
				length.pos.offset,
				length.end.offset,
				"Make with capacity instead of length",
				fmt.tprintf("0, %s", text),
			},
		)
	}
}

// The call this identifier names, either `f(…)` or `pkg.f(…)`.
@(private = "file")
called :: proc(use: IdentUse) -> (call: ^ast.Call_Expr, name: string) {
	n := len(use.parents)
	if n == 0 do return

	if c, is_call := use.parents[n - 1].derived.(^ast.Call_Expr); is_call {
		if (c.expr.derived.(^ast.Ident) or_else nil) == use.ident {
			return c, use.ident.name
		}
		return
	}
	if sel, is_sel := use.parents[n - 1].derived.(^ast.Selector_Expr); is_sel && n >= 2 {
		if (sel.field.derived.(^ast.Ident) or_else nil) != use.ident do return
		if c, is_call := use.parents[n - 2].derived.(^ast.Call_Expr); is_call {
			if (c.expr.derived.(^ast.Selector_Expr) or_else nil) == sel {
				return c, use.ident.name
			}
		}
	}
	return
}

@(private = "file")
allocates :: proc(name: string) -> bool {
	switch name {
	case "make",
	     "new",
	     "new_clone",
	     "clone",
	     "to_string",
	     "concatenate",
	     "join",
	     "aprintf",
	     "aprintfln",
	     "aprint",
	     "aprintln":
		return true
	}
	return strings.has_prefix(name, "clone_") || strings.has_suffix(name, "_clone")
}

@(private = "file")
frees :: proc(name: string) -> bool {
	switch name {
	case "delete", "free", "delete_string", "delete_slice", "delete_map", "delete_dynamic_array":
		return true
	}
	return false
}

// ponytail: an allocator argument is recognised by its source text, so two different
// allocators spelled the same way compare equal.
@(private = "file")
allocator_arg :: proc(src: string, call: ^ast.Call_Expr) -> (arg: ^ast.Expr, ok: bool) {
	for a in call.args {
		field_value := a.derived.(^ast.Field_Value) or_else nil
		if field_value == nil do continue
		field := field_value.field.derived.(^ast.Ident) or_else nil
		if field != nil && field.name == "allocator" do return field_value.value, true
	}
	if len(call.args) == 0 do return

	last := call.args[len(call.args) - 1]
	text := strip_space(node_text(src, last))
	if strings.has_prefix(text, "context.temp_allocator") do return last, true
	_, is_ident := last.derived.(^ast.Ident)
	_, is_selector := last.derived.(^ast.Selector_Expr)
	if (is_ident || is_selector) && strings.contains(text, "allocator") do return last, true
	return
}

// A free takes its allocator by position, whatever the argument is called.
@(private = "file")
free_allocator :: proc(src: string, call: ^ast.Call_Expr) -> (arg: ^ast.Expr, ok: bool) {
	if a, found := allocator_arg(src, call); found do return a, true
	if len(call.args) >= 2 do return call.args[len(call.args) - 1], true
	return
}

@(private = "file")
assigned_name :: proc(parents: []^ast.Node, call: ^ast.Call_Expr) -> (name: string, ok: bool) {
	#reverse for parent in parents {
		names, values, is_store := store_parts(parent)
		if !is_store do continue
		if len(names) != 1 || len(values) != 1 do return
		if (values[0].derived.(^ast.Call_Expr) or_else nil) != call do return
		ident := names[0].derived.(^ast.Ident) or_else nil
		if ident == nil do return
		return ident.name, true
	}
	return
}

@(private = "file")
store_parts :: proc(node: ^ast.Node) -> (names: []^ast.Expr, values: []^ast.Expr, ok: bool) {
	#partial switch n in node.derived {
	case ^ast.Value_Decl:
		if !n.is_mutable do return
		return n.names, n.values, true
	case ^ast.Assign_Stmt:
		return n.lhs, n.rhs, true
	}
	return
}

@(private = "file")
last_alloc :: proc(allocs: []Alloc, name: string, before: int) -> (found: Alloc, ok: bool) {
	for alloc in allocs {
		if alloc.name == name && alloc.offset < before {
			found, ok = alloc, true
		}
	}
	return
}

// The first use of `name` that is not `len(x)` or `cap(x)` appends to it.
@(private = "file")
grown_by_append :: proc(uses: []IdentUse, name: string) -> bool {
	for use in uses {
		if use.ident.name != name do continue
		if measured(use) do continue
		return appended(use)
	}
	return false
}

@(private = "file")
measured :: proc(use: IdentUse) -> bool {
	n := len(use.parents)
	if n == 0 do return false
	call := use.parents[n - 1].derived.(^ast.Call_Expr) or_else nil
	if call == nil do return false
	callee := call.expr.derived.(^ast.Ident) or_else nil
	return callee != nil && (callee.name == "len" || callee.name == "cap")
}

@(private = "file")
appended :: proc(use: IdentUse) -> bool {
	n := len(use.parents)
	if n < 2 do return false
	unary := use.parents[n - 1].derived.(^ast.Unary_Expr) or_else nil
	if unary == nil || unary.op.kind != .And do return false
	call := use.parents[n - 2].derived.(^ast.Call_Expr) or_else nil
	if call == nil || len(call.args) == 0 do return false
	if (call.args[0].derived.(^ast.Unary_Expr) or_else nil) != unary do return false
	callee := call.expr.derived.(^ast.Ident) or_else nil
	if callee == nil do return false

	switch callee.name {
	case "append", "append_elem", "append_elems", "append_elem_string":
		return true
	}
	return false
}
