package server

import "core:odin/ast"

// rols: like active_when_block, but a cursor inside another branch selects that branch, so a local declared in an
// inactive branch has a symbol there. Code outside the branch never sees its locals.
when_block_at :: proc(
	ast_context: ^AstContext,
	stmt: ^ast.When_Stmt,
	consts: map[string]When_Expr,
	offset: int,
) -> (
	^ast.Block_Stmt,
	bool,
) {
	for branch: ^ast.Stmt = stmt; branch != nil; {
		when_branch, is_when := branch.derived.(^ast.When_Stmt)
		body := when_branch.body if is_when else branch
		if block, ok := body.derived.(^ast.Block_Stmt); ok && block.pos.offset <= offset && offset <= block.end.offset {
			return block, true
		}
		branch = when_branch.else_stmt if is_when else nil
	}
	return active_when_block(ast_context, stmt, consts)
}

// rols: `lookup` that sets a declaration of an inactive `when` branch aside in `fallback`, keeping the first, and
// reports it missing. A resolver returns the fallback only after every later scope, such as the builtins, misses.
lookup_active :: proc(name, pkg, current_file: string, fallback: ^Maybe(Symbol)) -> (Symbol, bool) {
	symbol, found := lookup(name, pkg, current_file)
	if !found || .Fallback not_in symbol.flags {
		return symbol, found
	}
	if fallback^ == nil do fallback^ = symbol
	return {}, false
}
