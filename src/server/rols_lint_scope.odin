package server

import "core:odin/ast"
import "core:slice"

import "src:common"

// The declaration of a name that is visible at an offset, found on the syntax tree. The whole-file
// resolve gives a local no declaration range, so lints that must tell two locals of one name apart
// compare scopes here.
Visible_Decl :: struct {
	// The declared name. For a field that `using` brings into scope, the name of the value when the
	// `using` names an identifier, else nil.
	ident:         ^ast.Ident,
	// The value written for the name in a value declaration, or nil.
	value:         ^ast.Expr,
	// The name is a field of a struct or bit_field that `using` brings into scope.
	through_using: bool,
}

// The last declaration of name in root at or before offset whose scope is still open at offset: a
// value declaration, a range value, a type-switch variable, a parameter or named result of an
// enclosing procedure, or a field that a `using` declaration, statement or parameter brings into
// scope. Only a `using` in an open scope resolves its type, once per lint run.
// A `when` body opens no scope, so its declarations count while the `when` encloses the declaration.
visible_declaration :: proc(ctx: ^LintContext, root: ^ast.Node, name: string, offset: int) -> Visible_Decl {
	Data :: struct {
		ctx:    ^LintContext,
		name:   string,
		offset: int,
		found:  Visible_Decl,
	}
	data := Data {
		ctx    = ctx,
		name   = name,
		offset = offset,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || node.pos.offset > data.offset do return nil
			declares :: proc(data: ^Data, names: []^ast.Expr, values: []^ast.Expr = nil) {
				for name, i in names {
					ident := name.derived.(^ast.Ident) or_continue
					if ident.name != data.name || ident.pos.offset > data.offset do continue
					data.found = {ident, values[i] if len(values) == len(names) else nil, false}
				}
			}
			// `using expr` declares name when the type of expr has a member of that name.
			using_declares :: proc(data: ^Data, expr: ^ast.Expr, names: []^ast.Expr = nil) {
				if expr == nil do return
				if data.ctx.using_members == nil {
					data.ctx.using_members = make(map[^ast.Expr][]string, context.temp_allocator)
				}
				members, cached := data.ctx.using_members[expr]
				if !cached {
					members = using_member_names_of(data.ctx.document, expr)
					data.ctx.using_members[expr] = members
				}
				if !slice.contains(members, data.name) do return
				ident, _ := (names[0] if len(names) > 0 else expr).derived.(^ast.Ident)
				data.found = {ident, nil, true}
			}
			#partial switch n in node.derived {
			case ^ast.When_Stmt:
				walk_when_body(visitor, n)
				return nil
			case ^ast.Value_Decl:
				declares(data, n.names, n.values)
				// The fields come into scope after the declaration, from its type or else from each value.
				if n.is_using && n.end.offset <= data.offset {
					if n.type != nil {
						using_declares(data, n.type, n.names)
					} else {
						for value in n.values do using_declares(data, value, n.names)
					}
				}
				return visitor
			case ^ast.Using_Stmt:
				if n.end.offset <= data.offset do for expr in n.list do using_declares(data, expr)
				return visitor
			}
			if !scope_open(node, data.offset) do return nil
			#partial switch n in node.derived {
			case ^ast.Range_Stmt:
				declares(data, n.vals)
			case ^ast.Type_Switch_Stmt:
				if tag, ok := n.tag.derived.(^ast.Assign_Stmt); ok do declares(data, tag.lhs)
			case ^ast.Proc_Lit:
				if n.type != nil && n.type.params != nil {
					for field in n.type.params.list {
						declares(data, field.names)
						if .Using in field.flags do using_declares(data, field.type, field.names)
					}
				}
				if n.type != nil && n.type.results != nil {
					for field in n.type.results.list do declares(data, field.names)
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
	return data.found
}

// The member names that a `using` of expr brings into scope, with the members of its own `using`
// fields; empty when expr does not resolve to a struct or bit_field. expr is a type or a value, as
// get_locals_using reads it.
@(private = "package")
using_member_names_of :: proc(document: ^Document, expr: ^ast.Expr) -> []string {
	expr := strip_parens_and_pointers(expr)
	if expr == nil do return {}
	ast_context: AstContext
	position_context: DocumentPositionContext
	at := common.get_token_range(expr^, document.ast.src).start
	if !ast_context_at(document, at, &ast_context, &position_context) do return {}
	symbol, _, ok := unwrap_procedure_until_struct_bit_field_or_package(&ast_context, expr)
	if !ok do return {}
	#partial switch v in symbol.value {
	case SymbolStructValue:
		return v.names
	case SymbolBitFieldValue:
		return v.names
	}
	return {}
}

// False for a node that opens a scope which ends at or before offset; true for any other node.
scope_open :: proc(node: ^ast.Node, offset: int) -> bool {
	#partial switch _ in node.derived {
	case ^ast.Block_Stmt,
	     ^ast.Case_Clause,
	     ^ast.If_Stmt,
	     ^ast.For_Stmt,
	     ^ast.Range_Stmt,
	     ^ast.Switch_Stmt,
	     ^ast.Type_Switch_Stmt,
	     ^ast.Proc_Lit:
		return offset < node.end.offset
	}
	return true
}

// Walks the condition and the statements of every branch of a `when` with visitor, but not the
// branch blocks themselves, because a `when` body opens no scope.
walk_when_body :: proc(visitor: ^ast.Visitor, n: ^ast.When_Stmt) {
	ast.walk(visitor, n.cond)
	if body, ok := n.body.derived.(^ast.Block_Stmt); ok {
		for stmt in body.stmts do ast.walk(visitor, stmt)
	} else {
		ast.walk(visitor, n.body)
	}
	if n.else_stmt == nil do return
	#partial switch e in n.else_stmt.derived {
	case ^ast.Block_Stmt:
		for stmt in e.stmts do ast.walk(visitor, stmt)
	case:
		ast.walk(visitor, n.else_stmt)
	}
}
