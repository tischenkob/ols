package server

import "core:odin/ast"

// The declaration of a name that is visible at an offset, found on the syntax tree. The whole-file
// resolve gives a local no declaration range, so lints that must tell two locals of one name apart
// compare scopes here. `using` is not followed.
Visible_Decl :: struct {
	ident: ^ast.Ident,
	// The value written for the name in a value declaration, or nil.
	value: ^ast.Expr,
}

// The last declaration of name in root at or before offset whose scope is still open at offset: a
// value declaration, a range value, a type-switch variable, or a parameter or named result of an
// enclosing procedure.
// A `when` body opens no scope, so its declarations count while the `when` encloses the declaration.
visible_declaration :: proc(root: ^ast.Node, name: string, offset: int) -> Visible_Decl {
	Data :: struct {
		name:   string,
		offset: int,
		found:  Visible_Decl,
	}
	data := Data {
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
					data.found = {ident, values[i] if len(values) == len(names) else nil}
				}
			}
			#partial switch n in node.derived {
			case ^ast.When_Stmt:
				walk_when_body(visitor, n)
				return nil
			case ^ast.Value_Decl:
				declares(data, n.names, n.values)
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
					for field in n.type.params.list do declares(data, field.names)
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
