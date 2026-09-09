package server

import "core:odin/ast"

// The parser gives an unlabeled break, continue or fallthrough an end equal to its start, so
// its source text is empty. Extend the end over the keyword.
fix_branch_stmt_ends :: proc(file: ^ast.File) {
	visitor := ast.Visitor {
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			if s, ok := node.derived.(^ast.Branch_Stmt); ok && s.label == nil && s.end.offset == s.pos.offset {
				s.end.offset += len(s.tok.text)
				s.end.column += len(s.tok.text)
			}
			return visitor
		},
	}
	for decl in file.decls {
		ast.walk(&visitor, decl)
	}
}
