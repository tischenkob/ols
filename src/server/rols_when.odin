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

// rols: the `fallback` that lookup_active set aside, or the declaration of a target that takes the `when` branches
// around node when the target that builds the file does not, as for code under `when ODIN_OS == .Linux` on darwin.
// The index keeps one fallback of a name, which can belong to another branch. Only a node of the open file is
// placed, since that needs its AST.
branch_fallback :: proc(ast_context: ^AstContext, node: ast.Ident, fallback: Maybe(Symbol)) -> (Symbol, bool) {
	symbol, ok := fallback.?
	if !ok do return {}, false
	if is_builtin_pkg(symbol.pkg) || node.pos.file != ast_context.file.fullpath do return symbol, true
	target, has_target := branch_target(ast_context.file, node.pos.offset, file_build_target(node.pos.file))
	if !has_target do return symbol, true
	if built, found := lookup_on_target(node.name, symbol.pkg, node.pos.file, target);
	   found && .Fallback not_in built.flags {
		return built, true
	}
	return symbol, true
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
// constant of the same package, and a selector `other.NAME` to a constant of package `other`. The value is unknown
// when it reads a mutable or fallback global, a constant that does not fold, or a cycle of constants. A name that no
// constant declares reads as false, like in any `when` condition, because it can be `true`, `ODIN_OS` or a define.
// The caller clears `when_ast_context` so that a selector does not read the open file's imports.
fold_package_when_const :: proc(symbol: Symbol, pkg: string) -> (When_Expr, bool) {
	envs := make(map[string]^map[string]When_Expr, context.temp_allocator)
	return fold_package_const(&envs, symbol, pkg)
}

// The value of a name whose fold is unknown. It has no derived node, so `resolve_when_expr` reads it as unknown. A
// name holds it while it folds and keeps it when the fold fails, so a cycle of constants ends instead of recursing
// forever. Nothing writes to it.
@(private = "file")
when_unknown: ast.Expr

// `envs` holds the folded constants of each package, keyed by name, and by `path.NAME` for a selector into the
// package at `path`.
@(private = "file")
fold_package_const :: proc(envs: ^map[string]^map[string]When_Expr, symbol: Symbol, pkg: string) -> (When_Expr, bool) {
	generic, is_generic := symbol.value.(SymbolGenericValue)
	if !is_generic do return {}, false
	consts := envs[pkg]
	if consts == nil {
		consts = new(map[string]When_Expr, context.temp_allocator)
		consts^ = make_when_expr_map()
		envs[pkg] = consts
	}
	uri, _ := common.parse_uri(symbol.uri, context.temp_allocator)
	refs := make([dynamic]^ast.Expr, context.temp_allocator)
	visitor := ast.Visitor {
		data = &refs,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			#partial switch n in node.derived {
			case ^ast.Ident:
				append((^[dynamic]^ast.Expr)(visitor.data), n)
			case ^ast.Selector_Expr:
				// The index replaced an import alias with the package path, which no other name contains.
				base, is_ident := n.expr.derived.(^ast.Ident)
				if is_ident && strings.contains(base.name, "/") do append((^[dynamic]^ast.Expr)(visitor.data), n)
				return nil
			case ^ast.Implicit_Selector_Expr:
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, generic.expr)
	for ref in refs {
		key, name, ref_pkg: string
		#partial switch r in ref.derived {
		case ^ast.Ident:
			key, name, ref_pkg = r.name, r.name, pkg
		case ^ast.Selector_Expr:
			ref_pkg = r.expr.derived.(^ast.Ident).name
			key, name = when_selector_key(ref_pkg, r.field.name), r.field.name
		}
		if key in consts do continue
		if ref_pkg != pkg do try_build_package(ref_pkg)
		named, found := lookup(name, ref_pkg, uri.path)
		// A name stays unset and reads as false, but a selector reads a declaration of the package or nothing.
		if !found && ref_pkg == pkg do continue
		consts[key] = &when_unknown
		if !found || .Mutable in named.flags || .Fallback in named.flags do continue
		consts[key] = fold_package_const(envs, named, ref_pkg) or_continue
	}
	return resolve_when_expr(consts^, generic.expr)
}

// rols: the key under which a fold of a package constant stores the value of `pkg.name`, where `pkg` is a full path.
when_selector_key :: proc(pkg, name: string) -> string {
	return strings.concatenate({pkg, ".", name}, context.temp_allocator)
}
