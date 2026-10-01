package server

import "base:runtime"
import "core:odin/ast"

// The parser gives an unlabeled break, continue or fallthrough an end equal to its start, so
// its source text is empty. Extend the end over the keyword. Enclosing nodes that ended with
// the branch copied its old end: a `do` block, the ifs of an else-if chain, a loop or `when`.
// Ancestors whose end still equals that offset take the new end, up to the first that differs.
fix_branch_stmt_ends :: proc(file: ^ast.File) {
	// parse_file runs with the document arena as context.allocator, which never frees.
	stack := make([dynamic]^ast.Node, runtime.heap_allocator())
	defer delete(stack)
	visitor := ast.Visitor {
		data = &stack,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			stack := (^[dynamic]^ast.Node)(visitor.data)
			if node == nil {
				pop(stack)
				return nil
			}
			if s, ok := node.derived.(^ast.Branch_Stmt); ok && s.label == nil && s.end.offset == s.pos.offset {
				old := s.end.offset
				s.end.offset += len(s.tok.text)
				s.end.column += len(s.tok.text)
				#reverse for parent in stack {
					if parent.end.offset != old do break
					parent.end = s.end
					if block, is_block := parent.derived.(^ast.Block_Stmt); is_block && block.uses_do {
						block.close = s.end
					}
				}
			}
			append(stack, node)
			return visitor
		},
	}
	for decl in file.decls {
		ast.walk(&visitor, decl)
	}
}
