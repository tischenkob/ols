package server

import "core:odin/ast"
import "core:strings"

import "src:common"

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

// rols: drops the hidden fallbacks that `uri` declared, before a reindex or removal of that file.
forget_hidden_fallbacks :: proc(collection: ^SymbolCollection, uri: string, fold := false) {
	for _, &pkg in collection.packages {
		for i := len(pkg.hidden_fallbacks) - 1; i >= 0; i -= 1 {
			symbol := pkg.hidden_fallbacks[i]
			if !(strings.equal_fold(uri, symbol.uri) if fold else uri == symbol.uri) do continue
			free_symbol(symbol, collection.allocator)
			ordered_remove(&pkg.hidden_fallbacks, i)
		}
	}
}

// rols: fills each name that no declaration holds any more with the first hidden fallback of that name.
restore_hidden_fallbacks :: proc(collection: ^SymbolCollection) {
	for _, &pkg in collection.packages {
		for i := 0; i < len(pkg.hidden_fallbacks); {
			symbol := pkg.hidden_fallbacks[i]
			if symbol.name in pkg.symbols {
				i += 1
				continue
			}
			pkg.symbols[symbol.name] = symbol
			ordered_remove(&pkg.hidden_fallbacks, i)
		}
	}
}

// rols: folds the value of constant `symbol` of package `pkg` for a `when` condition. A name in it folds to a
// constant of the same package. A selector in it, which reads a third package, is unknown. A name whose value does
// not fold, through such a selector or a cycle, reads as false.
// The caller clears `when_ast_context` so that a selector does not read the open file's imports.
fold_package_when_const :: proc(symbol: Symbol, pkg: string) -> (When_Expr, bool) {
	consts := make_when_expr_map()
	return fold_package_const(&consts, symbol, pkg)
}

// Each name is folded once and stored as a value. It reads false while it folds and stays false when it fails, so a
// cycle of constants ends instead of recursing forever.
@(private = "file")
fold_package_const :: proc(consts: ^map[string]When_Expr, symbol: Symbol, pkg: string) -> (When_Expr, bool) {
	generic, is_generic := symbol.value.(SymbolGenericValue)
	if !is_generic do return {}, false
	uri, _ := common.parse_uri(symbol.uri, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	visitor := ast.Visitor {
		data = &names,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			#partial switch n in node.derived {
			case ^ast.Ident:
				append((^[dynamic]string)(visitor.data), n.name)
			case ^ast.Selector_Expr, ^ast.Implicit_Selector_Expr:
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, generic.expr)
	for name in names {
		if name in consts do continue
		named, found := lookup(name, pkg, uri.path)
		if !found || .Mutable in named.flags || .Fallback in named.flags do continue
		consts[name] = false
		consts[name] = fold_package_const(consts, named, pkg) or_continue
	}
	return resolve_when_expr(consts^, generic.expr)
}
