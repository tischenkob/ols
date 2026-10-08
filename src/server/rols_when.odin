package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
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
		if block, ok := body.derived.(^ast.Block_Stmt);
		   ok && block.pos.offset <= offset && offset <= block.end.offset {
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
// The index keeps one fallback of a name, which can belong to another branch. A node of another file than the open
// one, such as a field type of an indexed struct, is placed in that file as node_file parses it. With
// package_name set, node names a package-level declaration of the document's package, so a declaration of the open
// file in a branch that the target takes wins: the document's globals hold the host's branches only.
branch_fallback :: proc(
	ast_context: ^AstContext,
	node: ast.Ident,
	fallback: Maybe(Symbol),
	package_name := false,
) -> (
	Symbol,
	bool,
) {
	symbol, ok := fallback.?
	if ok && is_builtin_pkg(symbol.pkg) do return symbol, true
	own :=
		package_name &&
		node.pos.file == ast_context.file.fullpath &&
		ast_context.current_package == ast_context.document_package &&
		(!ok || symbol.pkg == ast_context.document_package)
	if !ok && !own do return {}, false
	file, placed := node_file(ast_context, node)
	if !placed do return symbol, ok
	candidates: []GlobalExpr
	if own do candidates = branch_globals(ast_context, file, node.name)
	if !ok && len(candidates) == 0 do return {}, false
	base := file_build_target(node.pos.file)
	plain: Gate_Consts
	if file.consts == nil do plain = branch_package_consts(ast_context, file.file^, base)
	target, has_target := branch_target(file.file^, node.pos.offset, base, &file.consts, plain)
	if !has_target {
		// Code that the host may not build keeps the fallback, but reaches a declaration of the open file that the
		// index lacks only in a branch that the build may take.
		_, excluded := file_target(node.pos.file)
		if excluded || when_eval_target != nil do return symbol, ok
		if ok && !branch_taken_on(file.file^, node.pos.offset, base, file.consts.?) do return symbol, ok
		return host_fallback(ast_context, node, fallback)
	}
	for &global in candidates {
		if branch_possible_on(file.file^, global.name_expr.pos.offset, target, file.consts.?) {
			return own_global_symbol(ast_context, node, &global, file.file^)
		}
	}
	if !ok do return {}, false
	if built, found := lookup_on_target(node.name, symbol.pkg, node.pos.file, target);
	   found && .Fallback not_in built.flags {
		return built, true
	}
	return symbol, true
}

// The fallback that code which the host builds for certain reaches: none when every declaration of the name in its
// package lies in a `when` branch that a known condition rules out on the host (`.Ruled_Out`), as odin then reports
// `Undeclared name`. A branch whose condition reads a name that the evaluator does not know may be the one that the
// build takes, so its declaration keeps the name reachable. The index holds one fallback of a name and the others
// that another file declares in `hidden_fallbacks`. The open file's own text stands in for what the index read from
// it, and a declaration of it that the index lacks is returned.
@(private = "file")
host_fallback :: proc(ast_context: ^AstContext, node: ast.Ident, fallback: Maybe(Symbol)) -> (Symbol, bool) {
	symbol, ok := fallback.?
	pkg := symbol.pkg if ok else ast_context.document_package
	open_in_pkg := ast_context.document_package == pkg
	open_uri := common.create_uri(ast_context.file.fullpath, context.temp_allocator).uri
	possible :: proc(indexed: Symbol, open_in_pkg: bool, open_uri: string) -> bool {
		return .Ruled_Out not_in indexed.flags && !(open_in_pkg && strings.equal_fold(indexed.uri, open_uri))
	}
	if ok {
		if possible(symbol, open_in_pkg, open_uri) do return symbol, true
		if indexed, found := indexer.index.collection.packages[pkg]; found {
			for hidden in indexed.hidden_fallbacks {
				if hidden.name == node.name && possible(hidden, open_in_pkg, open_uri) do return symbol, true
			}
		}
	}
	if !open_in_pkg do return {}, false
	probe := node
	probe.pos.file = ast_context.file.fullpath
	open_file, has_open := node_file(ast_context, probe)
	if !has_open do return {}, false
	for &global in branch_globals(ast_context, open_file, node.name) {
		if .Ruled_Out in global.flags do continue
		if ok do return symbol, true
		return own_global_symbol(ast_context, node, &global, open_file.file^)
	}
	return {}, false
}

// The symbol of global, a declaration of the open file named like node. Like an indexed symbol, it spans the
// declaration's name, which go to definition reads.
@(private = "file")
own_global_symbol :: proc(
	ast_context: ^AstContext,
	node: ast.Ident,
	global: ^GlobalExpr,
	file: ast.File,
) -> (
	Symbol,
	bool,
) {
	own_symbol, resolved := resolve_global_identifier(ast_context, node, global)
	own_symbol.range = common.get_token_range(global.name_expr^, file.src)
	own_symbol.uri = common.create_uri(global.name_expr.pos.file, ast_context.allocator).uri
	return own_symbol, resolved
}

// The constants of the package of file that base builds, from package_consts, cached in ast_context.
@(private = "file")
branch_package_consts :: proc(ast_context: ^AstContext, file: ast.File, base: parser.Build_Target) -> Gate_Consts {
	forward, _ := filepath.replace_separators(file.fullpath, '/', context.temp_allocator)
	dir := path.dir(forward, context.temp_allocator)
	key := fmt.tprintf("%v\x00%v\x00%v\x00%v", dir, file.pkg_name, base.os, base.arch)
	if ast_context.branch_packages == nil {
		ast_context.branch_packages = make(map[string]Gate_Consts, context.temp_allocator)
	}
	if consts, cached := ast_context.branch_packages[key]; cached do return consts
	consts := package_consts(dir, file.pkg_name, base)
	ast_context.branch_packages[key] = consts
	return consts
}

// rols: a file that branch_fallback places names in, parsed once per AstContext, with its constants and, for the
// open file, its declarations in `when` branches from branch_globals.
Branch_File :: struct {
	file:    ^ast.File,
	consts:  Branch_Constants,
	globals: Maybe([]GlobalExpr),
}

// The declarations named name in the `when` branches of file, every branch, flagged as `collect_globals` flags
// them for the index. The conditions read the file's constants, and those of the open file read its imports too.
// The first call collects them all into file.globals.
@(private = "file")
branch_globals :: proc(ast_context: ^AstContext, file: ^Branch_File, name: string) -> []GlobalExpr {
	if file.globals == nil {
		tags := parser.parse_file_tags(file.file^, context.temp_allocator)
		exprs := make([dynamic]GlobalExpr, context.temp_allocator)
		consts := make_when_expr_map()
		fold_when_file_consts(&consts, file.file^)
		saved := swap_when_ast_context(ast_context if file.file == &ast_context.file else nil)
		defer swap_when_ast_context(saved)
		for decl in file.file.decls {
			#partial switch d in decl.derived {
			case ^ast.Value_Decl:
				register_when_consts_from_value_decl(&consts, file.file^, d)
			case ^ast.When_Stmt:
				collect_when_stmt(&exprs, file.file^, tags, d, &consts, fallbacks = true)
			}
		}
		file.globals = exprs[:]
	}
	named := make([dynamic]GlobalExpr, context.temp_allocator)
	for global in file.globals.? {
		if global.name == name do append(&named, global)
	}
	return named[:]
}

// The file that holds node, from ast_context.branch_files: the open file, else node's file, parsed from its text on
// disk, which the index read, else from the text that file_text reads, as for a test source. ok is false when that
// text does not hold node's name at node's offset, as after an edit that the index has not read yet. The pointer
// holds until the next insert into ast_context.branch_files.
@(private = "file")
node_file :: proc(ast_context: ^AstContext, node: ast.Ident) -> (^Branch_File, bool) {
	if node.pos.file == "" do return nil, false
	if ast_context.branch_files == nil {
		ast_context.branch_files = make(map[string]Branch_File, context.temp_allocator)
	}
	entry, cached := &ast_context.branch_files[node.pos.file]
	if !cached {
		file: ^ast.File
		if node.pos.file == ast_context.file.fullpath {
			file = &ast_context.file
		} else {
			data, err := os.read_entire_file(node.pos.file, context.temp_allocator)
			text, read := string(data), err == nil
			if !read do text, read = file_text(node.pos.file)
			if read {
				file = new_clone(ast.File{src = text, fullpath = node.pos.file}, context.temp_allocator)
				p := parser.Parser {
					flags = {.Optional_Semicolons},
				}
				if !parse_file(&p, file, context.temp_allocator) do file = nil
			}
		}
		ast_context.branch_files[node.pos.file] = {
			file = file,
		}
		entry = &ast_context.branch_files[node.pos.file]
	}
	if entry.file == nil do return nil, false
	if entry.file == &ast_context.file do return entry, true
	end := node.pos.offset + len(node.name)
	return entry, end <= len(entry.file.src) && entry.file.src[node.pos.offset:end] == node.name
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
// constant declares reads as false, like in any `when` condition, because it can be `true`, `ODIN_OS` or a define,
// but `when_guessed` marks that false as a guess, as for a builtin that the editor does not seed, such as
// `ODIN_DEBUG`. The caller clears `when_ast_context` so that a selector does not read the open file's imports.
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
		// A name stays unset and reads as a guessed false, but a selector reads a declaration of the package or nothing.
		if !found && ref_pkg == pkg do continue
		consts[key] = &when_unknown
		if !found || .Mutable in named.flags || .Fallback in named.flags do continue
		// The guess of one constant marks only the conditions that read it.
		outer := when_guessed
		when_guessed = false
		value, folded := fold_package_const(envs, named, ref_pkg)
		guessed := when_guessed
		when_guessed = outer
		if folded do consts[key] = when_guess(value) if guessed else value
	}
	return resolve_when_expr(consts^, generic.expr)
}

// rols: the key under which a fold of a package constant stores the value of `pkg.name`, where `pkg` is a full path.
when_selector_key :: proc(pkg, name: string) -> string {
	return strings.concatenate({pkg, ".", name}, context.temp_allocator)
}

// rols: set while a `when` evaluation reads a name that it does not know, such as an undeclared name, a builtin that
// the editor does not seed or a constant that reads one. resolve_when_ident reads such a name as false, as upstream
// OLS does, so the branch that the editor picks stays the same. when_condition_known reads the flag to tell that
// guess from a known false. Each reader clears it before an evaluation and restores it after.
@(thread_local)
when_guessed: bool

// rols: set while collect_when_stmt collects a branch that it picked through a guess, so register_when_const
// stores each constant of the branch as a guess.
@(thread_local)
when_branch_guessed: bool

// Whether the branch of when_decl that get_when_block_stmt picks depends on a condition that is not known: that
// condition or one before it in the chain.
when_pick_guessed :: proc(when_decl: ^ast.When_Stmt, when_expr_map: map[string]When_Expr) -> bool {
	for branch := when_decl; branch != nil; {
		value, known := when_condition_known(branch.cond, when_expr_map)
		if !known do return true
		if value do return false
		if branch.else_stmt == nil do break
		branch, _ = branch.else_stmt.derived.(^ast.When_Stmt)
	}
	return false
}

// The stored values of a constant whose fold is a guess, which `resolve_when_expr` reads back as one. Nothing
// writes to them.
@(private = "file")
when_guess_false, when_guess_true: ast.Expr

// The value to store for a constant whose fold is the guess `value`. A guess is a bool, since an unknown name reads
// as false; any other value is stored as unknown.
when_guess :: proc(value: When_Expr) -> When_Expr {
	b, is_bool := value.(bool)
	if !is_bool do return &when_unknown
	return &when_guess_true if b else &when_guess_false
}

// The bool that `expr` stores when it is a guess from when_guess, which sets when_guessed.
guessed_when_value :: proc(expr: ^ast.Expr) -> (When_Expr, bool) {
	if expr != &when_guess_false && expr != &when_guess_true do return nil, false
	when_guessed = true
	return expr == &when_guess_true, true
}

// `left && right` or `left || right` for resolve_when_expr. An operand that folds to a known bool that decides the
// result, false for `&&` and true for `||`, gives that result whatever the other one reads. Otherwise both operands
// must fold to bools, and the result is a guess when either one is.
when_logic :: proc(when_expr_map: map[string]When_Expr, expr: ^ast.Binary_Expr) -> (When_Expr, bool) {
	outer := when_guessed
	decider := expr.op.kind == .Cmp_Or
	values, bools, guesses: [2]bool
	for operand, i in ([2]^ast.Expr{expr.left, expr.right}) {
		when_guessed = false
		value, _ := resolve_when_expr(when_expr_map, operand)
		values[i], bools[i] = value.(bool)
		guesses[i] = when_guessed
	}
	when_guessed = outer
	for i in 0 ..< 2 {
		if bools[i] && !guesses[i] && values[i] == decider do return decider, true
	}
	if !bools[0] || !bools[1] do return {}, false
	when_guessed = outer || guesses[0] || guesses[1]
	return values[0] || values[1] if decider else values[0] && values[1], true
}

// The value of the `when` condition cond as resolve_when_condition reads it, and whether that value is known: the
// condition folds to a bool without a guess. A condition that is not known may hold on the build, whatever its
// value reads.
when_condition_known :: proc(cond: ^ast.Expr, when_expr_map: map[string]When_Expr) -> (value, known: bool) {
	if cond == nil do return false, false
	outer := when_guessed
	when_guessed = false
	folded, ok := resolve_when_expr(when_expr_map, cond)
	guessed := when_guessed
	when_guessed = outer
	b, is_bool := folded.(bool)
	return ok && is_bool && b, ok && is_bool && !guessed
}
