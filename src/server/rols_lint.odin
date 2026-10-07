package server

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "src:common"

LintContext :: struct {
	document:       ^Document,
	config:         ^common.Config,
	src:            string,
	symbols:        Maybe(SymbolAndNodeMap),
	// The nodes of active code that `lint_symbols` leaves out, filled with it (see `lint_fallback`).
	fallbacks:      SymbolAndNodeMap,
	// Names the file uses as values (see `value_names`), built on first use.
	value_names:    Maybe(map[string]struct{}),
	// Names the file's calls give their arguments (see `named_arguments`), built on first use.
	named_args:     Maybe(map[string]struct{}),
	// Nodes a lint excluded while visiting their parent: deferred statements, proc literals whose signature
	// an attribute fixes, callback literals, and procedures the file uses as values.
	skip:           map[^ast.Node]struct{},
	fixes:          [dynamic]Lint_Fix,
	// The node being linted is in code the host does not build: an inactive `when` branch or an excluded file
	// that no known target builds.
	inactive:       bool,
	// The target that builds the file when the host does not, which decides its `when` branches and which
	// declarations its names may resolve to (see `lint_symbols`).
	target:         Maybe(parser.Build_Target),
	// For each file uri of a resolved declaration, whether target builds it, filled on first use.
	target_built:   map[string]bool,
	// Whether the package binds a C library (see `check_c_name` in rols_lint_naming.odin), found on first use.
	foreign_import: Maybe(bool),
	// The walker's context without locals; its globals tell which declarations are file-private.
	ast_context:    ^AstContext,
	// The walker's `when` environment, which ast_context belongs to.
	when_env:       ^When_Env,
	// Stands in for the files of the package when given (see `package_siblings`).
	files:          []Package_File,
	// The other files of the package, read on first use (see `used_as_value_elsewhere`).
	siblings:       ^Sibling_Values,
	// For each declaration that a name in inactive code resolved to, whether it has platform variants (see
	// `ambiguous_in_inactive`), and the documents read to find them.
	variants:       map[string]bool,
	hierarchy:      ^Call_Hierarchy,
	variant_dirs:   map[string]struct{}, // the package directories read into variant_files
	variant_files:  [dynamic]Package_File,
	// What each `using` expression that `visible_declaration` resolved brings into scope, in temp memory.
	using_members:  map[^ast.Expr]Using_Scope,
}

// A single-edit fix for one diagnostic, offered as a quick fix at the cursor.
Lint_Fix :: struct {
	start, end:  int,
	title, text: string,
	code:        string, // the modernize rule id: the diagnostic code, with a suffix for alternative fixes
}

@(private = "package")
is_top_level :: proc(ctx: ^LintContext, decl: ^ast.Value_Decl) -> bool {
	stmt := top_level_stmt_at(ctx.document.ast.decls[:], decl.pos.offset)
	return stmt != nil && declares(stmt, decl)
}

// The first top-level statement that ends after `offset`. Statements are in source order, so a
// per-node lint finds the one that holds a node without scanning the whole file.
@(private = "package")
top_level_stmt_at :: proc(decls: []^ast.Stmt, offset: int) -> ^ast.Stmt {
	lo, hi := 0, len(decls)
	for lo < hi {
		mid := (lo + hi) / 2
		if decls[mid].end.offset <= offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return decls[lo] if lo < len(decls) else nil
}

// A file-scope `when` holds declarations that are still top level.
@(private = "file")
declares :: proc(stmt: ^ast.Stmt, decl: ^ast.Value_Decl) -> bool {
	if stmt == nil do return false
	#partial switch s in stmt.derived {
	case ^ast.Value_Decl:
		return s == decl
	case ^ast.Block_Stmt:
		for inner in s.stmts do if declares(inner, decl) do return true
	case ^ast.When_Stmt:
		return declares(s.body, decl) || declares(s.else_stmt, decl)
	}
	return false
}

// The file's resolved nodes. In active code it leaves out the ones that resolve to a declaration only an inactive
// `when` branch makes: the host does not build such a declaration, so no lint judges a use by it there. In inactive
// code such a declaration is the right target, so the whole map comes back. In a file that the host does not build,
// it also leaves out the nodes that resolve to a declaration in a file that the target building it does not build:
// a lookup that this target cannot answer falls back to the host's declarations.
lint_symbols :: proc(ctx: ^LintContext) -> SymbolAndNodeMap {
	// The whole-file resolve is cached on the document.
	if ctx.inactive do return resolve_entire_file(ctx.document)
	symbols, has_symbols := ctx.symbols.?
	if has_symbols do return symbols
	symbols, ctx.fallbacks = split_fallbacks(resolve_entire_file(ctx.document))
	if _, has_target := ctx.target.?; has_target do symbols = drop_unbuilt(ctx, symbols)
	ctx.symbols = symbols
	return symbols
}

// Whether the target that builds the file builds the declaration of symbol. Always true in a file the host builds.
@(private = "package")
lint_target_builds :: proc(ctx: ^LintContext, symbol: Symbol) -> bool {
	target, has_target := ctx.target.?
	// The target builds the file being linted, whose text may live only in its document.
	if !has_target || symbol.uri == ctx.document.uri.uri do return true
	if ctx.target_built == nil do ctx.target_built = make(map[string]bool, context.temp_allocator)
	built, known := ctx.target_built[symbol.uri]
	if !known {
		built = target_builds_uri(symbol.uri, target)
		ctx.target_built[symbol.uri] = built
	}
	return built
}

// symbols without the nodes whose declaration the target of the file does not build, a copy when any is dropped.
@(private = "file")
drop_unbuilt :: proc(ctx: ^LintContext, symbols: SymbolAndNodeMap) -> SymbolAndNodeMap {
	kept := symbols
	copied := false
	for node, entry in symbols {
		if entry.symbol == nil || lint_target_builds(ctx, entry.symbol^) do continue
		if !copied {
			kept = make(SymbolAndNodeMap, len(symbols), context.temp_allocator)
			for key, value in symbols do kept[key] = value
			copied = true
		}
		delete_key(&kept, node)
	}
	return kept
}

// The symbol of a node in active code that `lint_symbols` leaves out because it resolves only to a declaration of
// an inactive `when` branch. A lint that reads a missing node as a local or a constant asks this first.
lint_fallback :: proc(ctx: ^LintContext, node: ^ast.Node) -> (^Symbol, bool) {
	if ctx.inactive do return nil, false
	lint_symbols(ctx)
	entry, found := ctx.fallbacks[uintptr(node)]
	return entry.symbol, found
}

// Whether a name in inactive code that resolves to symbol may name another declaration on a target that builds
// that code. The resolver gives the declaration of the host, or of the target that builds an excluded file, unless
// only an inactive branch declares the name (.Fallback), and a target that builds the inactive code may build a
// platform variant of it instead (see `declaration_variants`), with another kind or attribute.
@(private = "package")
ambiguous_in_inactive :: proc(ctx: ^LintContext, symbol: ^Symbol) -> bool {
	_, has_target := ctx.target.?
	// Another target than the one the lints evaluate may build an excluded file too, with other variants.
	if !(ctx.inactive || has_target) || symbol == nil || .Fallback in symbol.flags do return false
	// A local, a keyword or a builtin has no package-level declaration, so it has no variants.
	if .Local in symbol.flags || symbol.type == .Keyword || symbol.uri == "" do return false
	key := fmt.tprintf("%s:%s", symbol.uri, symbol.name)
	if ambiguous, found := ctx.variants[key]; found do return ambiguous
	if ctx.hierarchy == nil {
		ctx.hierarchy = new_clone(
			Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)},
			context.temp_allocator,
		)
		ctx.variants = make(map[string]bool, context.temp_allocator)
		ctx.variant_dirs = make(map[string]struct{}, context.temp_allocator)
		ctx.variant_files = make([dynamic]Package_File, context.temp_allocator)
	}
	// Without files that stand in for the disk, each package directory is read once per run, not once per
	// sibling and declaration.
	if len(ctx.files) == 0 {
		dir := filepath.dir(common.uri_to_path(symbol.uri, context.temp_allocator))
		if dir not_in ctx.variant_dirs {
			ctx.variant_dirs[dir] = {}
			if files, ok := read_package_files(dir); ok do append(&ctx.variant_files, ..files)
			ctx.hierarchy.files = ctx.variant_files[:]
		}
	}
	ambiguous := len(declaration_variants(ctx.hierarchy, symbol^)) > 0
	ctx.variants[key] = ambiguous
	return ambiguous
}

// symbols split into the nodes that do not resolve to a declaration only an inactive `when` branch makes, and the
// ones that do. The resolved map is cached on the document, so the split ones are copies, made only when needed.
@(private = "package")
split_fallbacks :: proc(symbols: SymbolAndNodeMap) -> (active, fallbacks: SymbolAndNodeMap) {
	active = symbols
	for _, resolved in symbols {
		if resolved.symbol == nil || .Fallback not_in resolved.symbol.flags do continue
		active = make(SymbolAndNodeMap, len(symbols), context.temp_allocator)
		fallbacks = make(SymbolAndNodeMap, context.temp_allocator)
		for node, entry in symbols {
			if entry.symbol != nil && .Fallback in entry.symbol.flags {
				fallbacks[node] = entry
			} else {
				active[node] = entry
			}
		}
		break
	}
	return
}

// A `{.Unnecessary}` literal inside a lint proc lives on its stack, and run_lints reads the
// diagnostics after the proc returns. These have static storage.
unnecessary_tags := []DiagnosticTag{.Unnecessary}
deprecated_tags := []DiagnosticTag{.Deprecated}

@(private = "file")
lints := [?]proc(_: ^LintContext, _: ^ast.Node, _: ^[dynamic]Diagnostic) {
	lint_self_assignment,
	lint_identical_branches,
	lint_unreachable_code,
	lint_float_equality,
	lint_printf,
	lint_ignored_result,
	lint_unused_parameter,
	lint_unused_variable,
	lint_naming,
	lint_bool_logic,
	lint_no_op,
	lint_loops,
	lint_dead_store,
	lint_allocator,
	lint_sync,
	lint_deprecated,
	lint_test_attribute,
	lint_core_misuse,
	lint_integer_range,
	lint_recursion,
	lint_imports,
	lint_invisible,
	lint_result_order,
	lint_switch,
	lint_redundant_type_assertion,
	lint_calls,
	lint_struct_literal,
	lint_pure_call,
}

// The lints that judge code by resolved symbols. They skip code that the host does not build, where a name can
// resolve to the active branch's declaration, unless it is a file that a known target builds: there they judge
// the code that this target builds by the declarations of this target. The other lints run everywhere: most read
// only the syntax. The naming and deprecated lints resolve a name only for its kind or attribute, and stay silent
// on a name whose declaration has platform variants there (see `ambiguous_in_inactive`). The unused-parameter lint
// resolves a mention only to spare a procedure that the file passes as a value, and counts a mention in inactive
// code by name (see `value_names`), so there it can only spare a parameter.
@(private = "file")
resolving_lints := [?]proc(_: ^LintContext, _: ^ast.Node, _: ^[dynamic]Diagnostic) {
	lint_float_equality,
	lint_printf,
	lint_ignored_result,
	lint_bool_logic,
	lint_no_op,
	lint_loops,
	lint_dead_store,
	lint_allocator,
	lint_sync,
	lint_core_misuse,
	lint_integer_range,
	lint_result_order,
	lint_switch,
	lint_calls,
	lint_struct_literal,
	lint_pure_call,
}

@(private = "file")
Walker :: struct {
	ctx:      LintContext,
	diags:    [dynamic]Diagnostic,
	// rols: resolution-dependent lints skip code in `when` branches that the host does not build.
	when_env: When_Env,
	inactive: int,
}

// The `when` branches of stmt, evaluated for the target that builds the file when the host does not.
@(private = "file")
walker_branches :: proc(w: ^Walker, stmt: ^ast.When_Stmt) -> []When_Branch {
	saved := when_eval_target
	defer when_eval_target = saved
	if target, has_target := w.ctx.target.?; has_target do when_eval_target = target
	return when_branches(&w.when_env, stmt)
}

// How the host builds a document: a `#+build ignore` file is built nowhere, and a file whose build tags or name
// leave out the host is excluded. The use-stdlib hints treat an excluded file like an inactive `when` branch, since
// its names can resolve to declarations that the target building it does not have, and so do the lints when no
// known target builds it (see `walk_lints`).
@(private = "package")
document_build :: proc(document: ^Document) -> (ignored, excluded: bool) {
	tags := parser.parse_file_tags(document.ast, context.temp_allocator)
	if tags.ignore do return true, true
	return false, !should_collect_file(tags) || skip_file(filepath.base(document.fullpath))
}

// What decides the `when` conditions of a document: its context without locals, whose globals also tell which
// declarations are file-private, and the constants of the file.
@(private = "package")
When_Env :: struct {
	ast_context: AstContext,
	consts:      map[string]When_Expr,
}

@(private = "package")
make_when_env :: proc(document: ^Document) -> When_Env {
	env := When_Env {
		ast_context = make_ast_context(
			document.ast,
			document.imports,
			document.package_name,
			document.uri.uri,
			document.fullpath,
			context.temp_allocator,
		),
		consts      = make_when_expr_map(),
	}
	get_globals(document.ast, &env.ast_context)
	register_when_consts_from_globals(&env.consts, env.ast_context.globals)
	return env
}

// One branch of a `when` chain: its condition (nil for the final `else`), its body, and whether the host builds it.
@(private = "package")
When_Branch :: struct {
	cond:   ^ast.Expr,
	body:   ^ast.Stmt,
	active: bool,
}

// The branches of the `when` chain that starts at stmt, in source order. The lint walker and the use-stdlib hints
// both read them, so the two agree on which code the host builds.
@(private = "package")
when_branches :: proc(env: ^When_Env, stmt: ^ast.When_Stmt) -> []When_Branch {
	active, _ := active_when_block(&env.ast_context, stmt, env.consts)
	branches := make([dynamic]When_Branch, context.temp_allocator)
	for branch: ^ast.Stmt = stmt; branch != nil; {
		when_branch, is_when := branch.derived.(^ast.When_Stmt)
		body := when_branch.body if is_when else branch
		block, is_block := body.derived.(^ast.Block_Stmt)
		append(&branches, When_Branch{when_branch.cond if is_when else nil, body, is_block && block == active})
		branch = when_branch.else_stmt if is_when else nil
	}
	return branches[:]
}

@(private = "file")
walk_when_branches :: proc(visitor: ^ast.Visitor, w: ^Walker, stmt: ^ast.When_Stmt) {
	for branch in walker_branches(w, stmt) {
		if branch.cond != nil do ast.walk(visitor, branch.cond)
		if !branch.active do w.inactive += 1
		ast.walk(visitor, branch.body)
		if !branch.active do w.inactive -= 1
	}
}

// One AST walk; every lint sees every node and checks its own config key. files, when given, stands in for the
// files of the package.
@(private = "file")
walk_lints :: proc(document: ^Document, config: ^common.Config, files: []Package_File) -> Walker {
	w := Walker {
		ctx = {
			document = document,
			config = config,
			src = string(document.text[:document.used_text]),
			skip = make(map[^ast.Node]struct{}, context.temp_allocator),
			fixes = make([dynamic]Lint_Fix, context.temp_allocator),
			files = files,
		},
		diags = make([dynamic]Diagnostic, context.temp_allocator),
	}
	// rols: nothing in a `#+build ignore` file is built, so nothing in it is linted. A file the host does not build
	// is linted for the target that builds it: its lookups reach that target's declarations, its `when` branches are
	// evaluated for it, and `lint_symbols` drops a name that resolves to a file it does not build. Without such a
	// target, the file is treated like an inactive branch (see `document_build`).
	ignored, excluded := document_build(document)
	if ignored do return w
	target: parser.Build_Target
	has_target := false
	if excluded do target, has_target = excluded_file_target(document.fullpath)
	if excluded && !has_target do w.inactive = 1
	saved_target := when_eval_target
	if has_target {
		// The whole-file resolve is cached on the document, so it evaluates `when` as every other request does.
		resolve_entire_file(document)
		w.ctx.target = target
		when_eval_target = target
	}
	w.when_env = make_when_env(document)
	when_eval_target = saved_target
	w.ctx.ast_context = &w.when_env.ast_context
	w.ctx.when_env = &w.when_env
	visitor := ast.Visitor {
		data = &w,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			w := (^Walker)(visitor.data)
			w.ctx.inactive = w.inactive > 0
			for lint in lints {
				// rols: a resolving lint would judge code by declarations that may belong to another platform.
				if w.inactive > 0 && slice.contains(resolving_lints[:], lint) do continue
				lint(&w.ctx, node, &w.diags)
			}
			// rols: track which branches of a `when` the host builds.
			if when_stmt, is_when := node.derived.(^ast.When_Stmt); is_when {
				walk_when_branches(visitor, w, when_stmt)
				return nil
			}
			return visitor
		},
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	return w
}

// A fix that would delete a comment is left out, for the quick fix and for modernize alike.
lint_fixes :: proc(document: ^Document, config: ^common.Config, files: []Package_File = {}) -> []Lint_Fix {
	fixes := walk_lints(document, config, files).ctx.fixes[:]
	kept := 0
	for fix in fixes {
		if fix_drops_comment(document.ast, fix.start, fix.end, fix.text) do continue
		fixes[kept] = fix
		kept += 1
	}
	return fixes[:kept]
}

lint_document :: proc(document: ^Document, config: ^common.Config, files: []Package_File = {}) -> []Diagnostic {
	w := walk_lints(document, config, files)
	if parser.parse_file_tags(document.ast, context.temp_allocator).ignore {
		return w.diags[:]
	}
	if config.enable_lint_simplify {
		for s in simplifications(document) {
			append(
				&w.diags,
				Diagnostic {
					range = {
						start = common.get_relative_token_position(s.start, document.text, 0),
						end = common.get_relative_token_position(s.end, document.text, 0),
					},
					severity = .Hint,
					code = s.code,
					message = simplification_message(s),
					tags = unnecessary_tags,
				},
			)
		}
	}
	if config.enable_lint_use_stdlib {
		for m in stdlib_matches(document) {
			append(
				&w.diags,
				Diagnostic {
					range = {
						start = common.get_relative_token_position(m.start, document.text, 0),
						end = common.get_relative_token_position(m.end, document.text, 0),
					},
					severity = .Hint,
					code = "use_stdlib",
					message = fmt.tprintf("Use %s", m.name),
					tags = unnecessary_tags,
				},
			)
		}
	}
	return w.diags[:]
}

run_lints :: proc(document: ^Document, config: ^common.Config) {
	if !config.enable_diagnostics {
		return
	}

	path := document.uri.path
	when ODIN_OS == .Windows {
		path = common.get_case_sensitive_path(path, context.temp_allocator)
	}
	uri := common.create_uri(path, context.temp_allocator)

	begin_lint_verdicts(document)
	defer end_lint_verdicts()
	remove_diagnostics(.Lint, uri.uri)
	for d in lint_document(document, config) {
		add_diagnostics(.Lint, uri.uri, d)
	}
}

@(private = "file")
lint_self_assignment :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_self_assignment do return
	assign, is_assign := node.derived.(^ast.Assign_Stmt)
	if !is_assign || assign.op.kind != .Eq do return

	before := len(diags)
	defer if len(diags) - before == len(assign.lhs) {
		start, end := whole_lines(ctx.src, node.pos.offset, node.end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove self-assignment", "", "self-assignment"})
	}

	for i in 0 ..< min(len(assign.lhs), len(assign.rhs)) {
		if contains_call(assign.rhs[i]) do continue
		lhs := strip_space(node_text(ctx.src, unparen(assign.lhs[i])))
		if lhs != strip_space(node_text(ctx.src, unparen(assign.rhs[i]))) do continue
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(assign, ctx.src),
				severity = .Warning,
				code = "self-assignment",
				message = fmt.tprintf("%s is assigned to itself", lhs),
			},
		)
	}
}

@(private = "file")
contains_call :: proc(root: ^ast.Expr) -> bool {
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			if _, ok := node.derived.(^ast.Call_Expr); ok {
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
	return found
}

@(private = "file")
lint_identical_branches :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_identical_branches do return

	#partial switch n in node.derived {
	case ^ast.If_Stmt:
		body, body_ok := n.body.derived.(^ast.Block_Stmt)
		if !body_ok || n.else_stmt == nil do return
		else_block, else_ok := n.else_stmt.derived.(^ast.Block_Stmt)
		if !else_ok do return
		if strip_space(block_inner_text(ctx.src, body)) != strip_space(block_inner_text(ctx.src, else_block)) do return
		range := common.get_token_range(n, ctx.src)
		range.end = common.get_token_range(n.cond, ctx.src).end
		append(
			diags,
			Diagnostic {
				range = range,
				severity = .Warning,
				code = "identical-branches",
				message = "if and else branches are identical",
			},
		)
	case ^ast.Ternary_If_Expr:
		if strip_space(node_text(ctx.src, n.x)) != strip_space(node_text(ctx.src, n.y)) do return
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(n, ctx.src),
				severity = .Warning,
				code = "identical-branches",
				message = "both ternary branches are identical",
			},
		)
	}
}

@(private = "file")
lint_unreachable_code :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_unreachable_code do return

	stmts: []^ast.Stmt
	#partial switch n in node.derived {
	case ^ast.Block_Stmt:
		stmts = n.stmts
	case ^ast.Case_Clause:
		stmts = n.body
	case:
		return
	}

	for stmt, i in stmts {
		if i + 1 >= len(stmts) do break
		if !terminates(stmt) do continue
		if only_constants(stmts[i + 1:]) do break
		range := common.get_token_range(stmts[i + 1], ctx.src)
		range.end = common.get_token_range(stmts[len(stmts) - 1], ctx.src).end
		append(
			diags,
			Diagnostic {
				range = range,
				severity = .Hint,
				code = "unreachable-code",
				message = "unreachable code",
				tags = unnecessary_tags,
			},
		)
		start, end := whole_lines(ctx.src, stmts[i + 1].pos.offset, stmts[len(stmts) - 1].end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove unreachable code", "", "unreachable-code"})
		return
	}
}

// The lines fully covering [start, end): grown to the line start when only whitespace precedes,
// and past the newline when only whitespace follows.
@(private = "package")
whole_lines :: proc(src: string, start, end: int) -> (int, int) {
	start, end := start, end
	line_start := start
	for line_start > 0 && src[line_start - 1] != '\n' do line_start -= 1
	if strings.trim_space(src[line_start:start]) == "" do start = line_start

	line_end := end
	for line_end < len(src) && src[line_end] != '\n' do line_end += 1
	if strings.trim_space(src[end:line_end]) == "" do end = min(line_end + 1, len(src))
	return start, end
}

// `x :: proc ...` after a return is hoisted, not dead.
@(private = "file")
only_constants :: proc(stmts: []^ast.Stmt) -> bool {
	for stmt in stmts {
		decl, is_decl := stmt.derived.(^ast.Value_Decl)
		if !is_decl || decl.is_mutable do return false
	}
	return true
}

@(private = "package")
terminates :: proc(stmt: ^ast.Stmt) -> bool {
	#partial switch s in stmt.derived {
	case ^ast.Return_Stmt:
		return true
	case ^ast.Branch_Stmt:
		#partial switch s.tok.kind {
		case .Break, .Continue, .Fallthrough:
			return true
		}
	case ^ast.Expr_Stmt:
		return is_panic_call(s)
	}
	return false
}

@(private = "package")
is_panic_call :: proc(stmt: ^ast.Stmt) -> bool {
	expr_stmt := stmt.derived.(^ast.Expr_Stmt) or_return
	call := expr_stmt.expr.derived.(^ast.Call_Expr) or_return
	callee := call.expr.derived.(^ast.Ident) or_return
	return callee.name == "panic" || callee.name == "unreachable"
}

@(private = "file")
lint_float_equality :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_float_equality do return
	binary, is_binary := node.derived.(^ast.Binary_Expr)
	if !is_binary || (binary.op.kind != .Cmp_Eq && binary.op.kind != .Not_Eq) do return
	if !is_float_operand(ctx, binary.left) && !is_float_operand(ctx, binary.right) do return
	// Comparing with a literal zero or one is a sentinel or flag test, not an arithmetic result.
	if is_zero_or_one_literal(binary.left) || is_zero_or_one_literal(binary.right) do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(binary, ctx.src),
			severity = .Information,
			code = "float-equality",
			message = "comparing floats with == is exact; consider an epsilon",
		},
	)
}

@(private = "file")
is_zero_or_one_literal :: proc(expr: ^ast.Expr) -> bool {
	lit, is_lit := ast.unparen_expr(expr).derived.(^ast.Basic_Lit)
	return is_lit && slice.contains([]string{"0", "0.0", "1", "1.0"}, lit.tok.text)
}

// The resolved-symbol map only holds identifiers and selectors, so an indexed or called float
// is only caught when the other operand is a float.
@(private = "package")
is_float_operand :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> bool {
	expr := expr
	for {
		#partial switch e in expr.derived {
		case ^ast.Paren_Expr:
			expr = e.expr
			continue
		case ^ast.Unary_Expr:
			expr = e.expr
			continue
		}
		break
	}

	#partial switch e in expr.derived {
	case ^ast.Basic_Lit:
		return e.tok.kind == .Float
	case ^ast.Ident, ^ast.Selector_Expr:
		resolved := lint_symbols(ctx)[uintptr(expr)] or_return
		// `T == f32` in a `when` compares types, and a type name resolves to the keyword.
		if resolved.symbol.type == .Keyword do return false
		#partial switch v in resolved.symbol.value {
		case SymbolBasicValue:
			return slice.contains(untyped_map[.Float], v.ident.name)
		case SymbolUntypedValue:
			return v.type == .Float
		}
	}
	return false
}

// The compiler rejects a discarded call result only when the callee is `@(require_results)`.
// The lint reports the same calls without waiting for `odin check`.
@(private = "file")
lint_ignored_result :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_ignored_result do return
	if deferred, is_defer := node.derived.(^ast.Defer_Stmt); is_defer {
		ctx.skip[deferred.stmt] = {}
		return
	}
	stmt := node.derived.(^ast.Expr_Stmt) or_else nil
	if stmt == nil || node in ctx.skip do return
	expr := stmt.expr
	for {
		paren := expr.derived.(^ast.Paren_Expr) or_break
		expr = paren.expr
	}
	call, is_call := expr.derived.(^ast.Call_Expr)
	if !is_call do return
	resolved, is_resolved := lint_symbols(ctx)[uintptr(call.expr)]
	if !is_resolved do return
	value, is_proc := resolved.symbol.value.(SymbolProcedureValue)
	if !is_proc || len(value.return_types) == 0 do return
	if !slice.contains(attribute_names(value.attributes), "require_results") do return

	callee := node_text(ctx.src, call.expr)
	name, has_name := result_type_name(ctx, value, resolved.symbol.pkg)
	append(
		diags,
		Diagnostic {
			range = common.get_token_range(stmt, ctx.src),
			severity = .Warning,
			code = "ignored-result",
			message = has_name ? fmt.tprintf("result of %s is ignored (%s)", callee, name) : fmt.tprintf("result of %s is ignored", callee),
		},
	)
}

// The first result type, written as this file would write it. `callee_pkg` is the package that declares the callee.
@(private = "file")
result_type_name :: proc(ctx: ^LintContext, value: SymbolProcedureValue, callee_pkg: string) -> (string, bool) {
	declared :=
		value.orig_return_types if len(value.orig_return_types) == len(value.return_types) else value.return_types
	type, pkg := declared[0].type, callee_pkg
	// A poly result is named by its instance, which the call site wrote.
	if type != nil && names_poly_param(type, poly_param_names(value.orig_arg_types)) {
		type, pkg = value.return_types[0].type, ctx.document.package_name
	}
	if type == nil do return "", false
	#partial switch t in type.derived {
	case ^ast.Ident:
		if is_builtin_type_name(t.name) do return t.name, true
		return qualified_type_name(ctx, pkg, t.name), true
	case ^ast.Selector_Expr:
		base, is_ident := t.expr.derived.(^ast.Ident)
		if t.field == nil || !is_ident do break
		// The indexer replaces the alias in the declaring file with that package's directory.
		if strings.contains(base.name, "/") do return qualified_type_name(ctx, base.name, t.field.name), true
		return fmt.tprintf("%s.%s", base.name, t.field.name), true
	}
	return node_to_string(type), true
}

// Resolves a type written in package `pkg` with ast_context, a context without locals for the open file, which
// keeps its own package. It saves building a context per call (see `resolve_type_in_package`).
@(private = "package")
resolve_type_with :: proc(ast_context: ^AstContext, pkg: string, type: ^ast.Expr) -> (Symbol, bool) {
	saved := ast_context.current_package
	defer ast_context.current_package = saved
	ast_context.current_package = pkg
	reset_ast_context(ast_context)
	return resolve_type_expression(ast_context, type)
}

// Resolves a type written in package `pkg`, which may be another package than the document's.
@(private = "package")
resolve_type_in_package :: proc(document: ^Document, pkg: string, type: ^ast.Expr) -> (Symbol, bool) {
	ast_context := package_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		pkg,
	)
	return resolve_type_expression(&ast_context, type)
}

// A context without locals that resolves names in package `pkg`, seen from the open file.
// It takes the file's fields because code actions hold an `AstContext` rather than the `Document`.
@(private = "package")
package_ast_context :: proc(
	file: ast.File,
	imports: []Package,
	document_package, uri, fullpath, pkg: string,
) -> AstContext {
	ast_context := make_ast_context(file, imports, document_package, uri, fullpath, context.temp_allocator)
	get_globals(file, &ast_context)
	ast_context.current_package = pkg
	return ast_context
}

// `name` declared in the package in directory `dir`, as this file writes it: bare in its own package,
// else with the import alias, else with the last segment of the directory.
@(private = "file")
qualified_type_name :: proc(ctx: ^LintContext, dir, name: string) -> string {
	if dir == "" || dir == "$builtin" || dir == ctx.document.package_name do return name
	for imp in ctx.document.imports {
		if imp.name == dir do return fmt.tprintf("%s.%s", imp.base, name)
	}
	last_slash := strings.last_index_byte(dir, '/')
	return fmt.tprintf("%s.%s", dir[last_slash + 1:], name)
}

@(private = "file")
lint_unused_parameter :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_unused_parameter do return

	lit: ^ast.Proc_Lit
	#partial switch n in node.derived {
	case ^ast.Value_Decl:
		// Visited before its Proc_Lit child, so the attributes are known by then.
		if len(n.values) != 1 do return
		lit = n.values[0].derived.(^ast.Proc_Lit) or_else nil
		if lit == nil do return
		if has_fixed_signature_attribute(n.attributes[:]) {
			ctx.skip[lit] = {}
		} else if len(unused_params(lit)) > 0 && is_signature_fixed_by_use(ctx, n) {
			ctx.skip[lit] = {}
		}
		return
	case ^ast.Call_Expr:
		// The callee's parameter type fixes the signature of a procedure literal argument.
		for arg in n.args do skip_context_typed_proc(ctx, arg)
		return
	case ^ast.Comp_Lit:
		for elem in n.elems do skip_context_typed_proc(ctx, elem)
		return
	case ^ast.Assign_Stmt:
		for rhs in n.rhs do skip_context_typed_proc(ctx, rhs)
		return
	case ^ast.Proc_Lit:
		lit = n
	case:
		return
	}

	if node in ctx.skip do return
	for ident in unused_params(lit) {
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(ident, ctx.src),
				severity = .Hint,
				code = "unused-parameter",
				message = fmt.tprintf("parameter %s is unused", ident.name),
				tags = unnecessary_tags,
			},
		)
		// A call naming the argument stops compiling once the parameter is `_`. Calls in other files are
		// checked only by the quick fix (see add_lint_fix_action).
		if declares_one_name(lit, ident) && ident.name not_in lint_named_arguments(ctx) {
			append(
				&ctx.fixes,
				Lint_Fix{ident.pos.offset, ident.end.offset, "Rename parameter to `_`", "_", "unused-parameter"},
			)
		}
	}
}

// A procedure literal passed as an argument, stored in a composite literal or assigned takes its signature
// from the parameter, field or variable type.
@(private = "file")
skip_context_typed_proc :: proc(ctx: ^LintContext, expr: ^ast.Expr) {
	expr := expr
	if field_value, is_field_value := expr.derived.(^ast.Field_Value); is_field_value do expr = field_value.value
	if lit, is_lit := expr.derived.(^ast.Proc_Lit); is_lit do ctx.skip[lit] = {}
}

// A declaration with an explicit type (`h: Handler = proc(…) {…}`) takes its signature from that type. A named
// procedure that the package uses as a value (an argument, an assignment, a composite literal element, a
// parameter default) has its signature fixed by the proc type it is stored in.
@(private = "file")
is_signature_fixed_by_use :: proc(ctx: ^LintContext, decl: ^ast.Value_Decl) -> bool {
	if decl.type != nil do return true
	if decl.is_mutable || len(decl.names) != 1 do return false
	name := decl.names[0].derived.(^ast.Ident) or_return
	if name.name in value_names(ctx) do return true
	// Other files see neither a local procedure nor a file-private one.
	if !is_top_level(ctx, decl) do return false
	if global, found := ctx.ast_context.globals[name.name]; found && global.private == .File do return false
	used := used_as_value_elsewhere(ctx, name.name)
	// A change to another file can turn this verdict (see `relint_package_siblings`).
	record_lint_verdict(ctx, name.name, used)
	return used
}

// The other files of the package, and the names that the ones parsed so far use as values.
Sibling_Values :: struct {
	files:  []Package_File,
	// For each identifier word, the indices into files of the files whose text holds it, ascending. Built after
	// WORD_SCANS names (see `used_as_value_elsewhere`).
	words:  Maybe(map[string][dynamic]int),
	scans:  int, // names looked up by scanning the text
	parsed: []bool,
	names:  map[string]struct{},
	bytes:  int, // parsed so far
}

// Parsing the other files of the package stops at this many bytes. Their text is read whatever its size.
@(private = "file")
MAX_SIBLING_PARSE_BYTES :: mem.Megabyte * 3 / 2

// Names looked up by scanning the text of the other files before their words are indexed. On src/server (2 MB) one
// scan takes about 2 ms and building the index about 10 ms, and most files look up at most two names.
@(private = "file")
WORD_SCANS :: 3

// Whether another file of the package uses name as a value. Only a file whose text holds the name as a word is
// parsed, each at most once per lint run. A mention counts by name: a local of that name in another file counts too.
// A file that does not parse, or that the parse limit leaves out, counts when it holds the name.
@(private = "file")
used_as_value_elsewhere :: proc(ctx: ^LintContext, name: string) -> bool {
	siblings := sibling_values(ctx)
	if name in siblings.names do return true
	if siblings.scans < WORD_SCANS {
		siblings.scans += 1
		for file, i in siblings.files {
			if contains_word(file.text, name) && parse_sibling(siblings, i, name) do return true
		}
		return false
	}
	words, indexed := siblings.words.?
	if !indexed {
		words = word_files(siblings.files)
		siblings.words = words
	}
	// A copy: ranging over the map element dereferences it, and a missing key has none.
	holders := words[name]
	for i in holders {
		if parse_sibling(siblings, i, name) do return true
	}
	return false
}

// The other files of the package, read on the first call of a lint run.
@(private = "package")
sibling_values :: proc(ctx: ^LintContext) -> ^Sibling_Values {
	if ctx.siblings == nil {
		files := package_siblings(ctx.document, ctx.files)
		ctx.siblings = new_clone(
			Sibling_Values {
				files = files,
				parsed = make([]bool, len(files), context.temp_allocator),
				names = make(map[string]struct{}, context.temp_allocator),
			},
			context.temp_allocator,
		)
	}
	return ctx.siblings
}

// Parses file i of siblings, unless it is parsed already, and reports whether name is a value use found so far.
// A file that does not parse, or that the parse limit leaves out, counts as a use.
@(private = "file")
parse_sibling :: proc(siblings: ^Sibling_Values, i: int, name: string) -> bool {
	if siblings.parsed[i] do return false
	file := siblings.files[i]
	if siblings.bytes + len(file.text) > MAX_SIBLING_PARSE_BYTES do return true
	siblings.bytes += len(file.text)
	siblings.parsed[i] = true
	context.allocator = context.temp_allocator
	parsed, ok := parse_syntax(file.fullpath, file.text)
	if !ok do return true
	for stmt in parsed.decls {
		for use in collect_ident_uses(stmt) {
			if is_value_use(use) do siblings.names[use.ident.name] = {}
		}
	}
	return name in siblings.names
}

// For each identifier word in the text of files, the indices of the files that hold it, in one scan of each file.
// A word is a maximal run of identifier characters, so it matches what `contains_word` finds. A byte stands for
// its rune: every byte of a multi-byte rune is at least 0x80, which `is_ident_rune` accepts.
@(private = "file")
word_files :: proc(files: []Package_File) -> map[string][dynamic]int {
	context.allocator = context.temp_allocator
	words := make(map[string][dynamic]int)
	for file, i in files {
		text := file.text
		for start := 0; start < len(text); {
			if !is_ident_rune(rune(text[start])) {
				start += 1
				continue
			}
			end := start + 1
			for end < len(text) && is_ident_rune(rune(text[end])) do end += 1
			_, list, _, _ := map_entry(&words, text[start:end])
			if len(list) == 0 || list[len(list) - 1] != i do append(list, i)
			start = end
		}
	}
	return words
}

// The bodies of the `when` branches that the host does not build, as offset ranges, or the whole file when the host
// does not build it.
@(private = "file")
inactive_spans :: proc(ctx: ^LintContext) -> [][2]int {
	spans := make([dynamic][2]int, context.temp_allocator)
	if _, excluded := document_build(ctx.document); excluded {
		append(&spans, [2]int{0, len(ctx.src)})
		return spans[:]
	}
	Search :: struct {
		env:   ^When_Env,
		spans: ^[dynamic][2]int,
	}
	search := Search{ctx.when_env, &spans}
	visitor := ast.Visitor {
		data = &search,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			stmt, is_when := node.derived.(^ast.When_Stmt)
			if !is_when do return visitor
			search := (^Search)(visitor.data)
			for branch in when_branches(search.env, stmt) {
				if branch.active {
					ast.walk(visitor, branch.body)
				} else {
					append(search.spans, [2]int{branch.body.pos.offset, branch.body.end.offset})
				}
			}
			return nil
		},
	}
	for decl in ctx.document.ast.decls do ast.walk(&visitor, decl)
	return spans[:]
}

@(private = "file")
in_spans :: proc(spans: [][2]int, offset: int) -> bool {
	for span in spans do if span[0] <= offset && offset < span[1] do return true
	return false
}

// The other .odin files in the directory of document, an open file with its unsaved text. files, when given,
// stands in for the disk.
@(private = "file")
package_siblings :: proc(document: ^Document, files: []Package_File) -> []Package_File {
	siblings := make([dynamic]Package_File, context.temp_allocator)
	dir := filepath.dir(document.fullpath)
	base := filepath.base(document.fullpath)
	package_files := files
	if len(package_files) == 0 {
		package_files, _ = read_package_files(dir)
	}
	for file in package_files {
		if filepath.base(file.fullpath) == base || filepath.dir(file.fullpath) != dir do continue
		append(&siblings, file)
	}
	return siblings[:]
}

// Every name the file mentions as a value, found in one walk. A mention counts when it resolves to a procedure
// or to nothing, so a same-named local variable does not hide an unused parameter.
@(private = "file")
value_names :: proc(ctx: ^LintContext) -> map[string]struct{} {
	names, has_names := ctx.value_names.?
	if has_names do return names

	names = make(map[string]struct{}, context.temp_allocator)
	symbols := resolve_entire_file(ctx.document)
	inactive := inactive_spans(ctx)
	for stmt in ctx.document.ast.decls {
		for use in collect_ident_uses(stmt) {
			if !is_value_use(use) do continue
			// rols: code the host does not build can resolve a name to the host's declaration, which may be a
			// variable where that code passes a procedure, so a mention there counts by name.
			if in_spans(inactive, use.ident.pos.offset) {
				names[use.ident.name] = {}
				continue
			}
			// A mention that resolves only to an inactive branch's declaration counts by name too.
			if resolved, found := symbols[uintptr(use.ident)];
			   found && !resolved.is_unresolved && .Fallback not_in resolved.symbol.flags {
				#partial switch _ in resolved.symbol.value {
				case SymbolProcedureValue, SymbolProcedureGroupValue:
				case:
					continue
				}
			}
			names[use.ident.name] = {}
		}
	}
	ctx.value_names = names
	return names
}

@(private = "file")
lint_named_arguments :: proc(ctx: ^LintContext) -> map[string]struct{} {
	names, has_names := ctx.named_args.?
	if !has_names {
		names = named_arguments(&ctx.document.ast)
		ctx.named_args = names
	}
	return names
}

// Every name a call in file gives an argument (`f(x, flag = true)` gives `flag`), whatever the callee.
named_arguments :: proc(file: ^ast.File) -> map[string]struct{} {
	names := make(map[string]struct{}, context.temp_allocator)
	for stmt in file.decls {
		for use in collect_ident_uses(stmt) {
			if len(use.parents) < 2 do continue
			field_value, is_field_value := use.parents[len(use.parents) - 1].derived.(^ast.Field_Value)
			if !is_field_value || field_value.field != use.ident do continue
			if _, is_call := use.parents[len(use.parents) - 2].derived.(^ast.Call_Expr); is_call {
				names[use.ident.name] = {}
			}
		}
	}
	return names
}

// A mention that neither declares a name, calls it, nor names a field, parameter or group member.
is_value_use :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 do return false
	#partial switch parent in use.parents[len(use.parents) - 1].derived {
	case ^ast.Call_Expr:
		return parent.expr != use.ident
	case ^ast.Selector_Expr:
		return parent.field != use.ident
	case ^ast.Field_Value:
		return parent.field != use.ident
	case ^ast.Value_Decl:
		return !slice.contains(parent.names, (^ast.Expr)(use.ident))
	case ^ast.Field:
		return parent.default_value == (^ast.Expr)(use.ident)
	case ^ast.Proc_Group, ^ast.Implicit_Selector_Expr:
		return false
	}
	return true
}

// `a, b: int` would need every name renamed to stay valid, so only a lone name gets a fix.
@(private = "file")
declares_one_name :: proc(lit: ^ast.Proc_Lit, ident: ^ast.Ident) -> bool {
	for param in lit.type.params.list {
		for name in param.names {
			if n, is_ident := name.derived.(^ast.Ident); is_ident && n == ident do return len(param.names) == 1
		}
	}
	return false
}

// Parameters the body never reads. Skips foreign and non-Odin procedures, empty and panic-only
// bodies, `using` and `_` names, and names tied to a polymorphic type.
unused_params :: proc(lit: ^ast.Proc_Lit) -> []^ast.Ident {
	if lit.body == nil || lit.type == nil || lit.type.params == nil do return {}
	if convention, is_string := lit.type.calling_convention.(string); is_string {
		convention = strings.trim(convention, "\"`")
		if convention != "odin" && convention != "contextless" do return {}
	}
	body, is_block := lit.body.derived.(^ast.Block_Stmt)
	if !is_block do return {}
	if len(body.stmts) == 0 || (len(body.stmts) == 1 && is_panic_call(body.stmts[0])) do return {}

	poly_names := poly_param_names(lit.type.params.list[:])

	unused := make([dynamic]^ast.Ident, context.temp_allocator)
	uses := collect_ident_uses(lit.body)
	for param in lit.type.params.list {
		if .Using in param.flags do continue
		if mentions_poly(param.type, poly_names) do continue
		names: for name in param.names {
			ident := name.derived.(^ast.Ident) or_continue
			if strings.has_prefix(ident.name, "_") do continue
			for use in uses {
				if use.ident.name == ident.name && !is_field_name(use) do continue names
			}
			append(&unused, ident)
		}
	}
	return unused[:]
}

// The left side of `field = value` names a struct field or a parameter, not a variable.
@(private = "file")
is_field_name :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 do return false
	field_value, ok := use.parents[len(use.parents) - 1].derived.(^ast.Field_Value)
	return ok && field_value.field == use.ident
}

// The names that `$` binds in a parameter list: `$T: typeid` and `x: $T` both bind T.
@(private = "file")
poly_param_names :: proc(params: []^ast.Field) -> map[string]struct{} {
	poly_names := make(map[string]struct{}, context.temp_allocator)
	for param in params {
		if param == nil do continue
		for name in param.names {
			if poly, ok := name.derived.(^ast.Poly_Type); ok do poly_names[poly.type.name] = {}
		}
		for use in collect_ident_uses(param.type) {
			if len(use.parents) > 0 {
				if _, ok := use.parents[len(use.parents) - 1].derived.(^ast.Poly_Type); ok do poly_names[use.ident.name] = {}
			}
		}
	}
	return poly_names
}

// A type that is a poly parameter itself: `$T`, or `T` bound by a `$` parameter.
@(private = "file")
names_poly_param :: proc(type: ^ast.Expr, poly_names: map[string]struct{}) -> bool {
	#partial switch t in type.derived {
	case ^ast.Poly_Type:
		return true
	case ^ast.Ident:
		return t.name in poly_names
	}
	return false
}

@(private = "file")
mentions_poly :: proc(type: ^ast.Expr, poly_names: map[string]struct{}) -> bool {
	if type == nil do return false
	for use in collect_ident_uses(type) {
		if use.ident.name in poly_names do return true
	}
	return false
}

has_fixed_signature_attribute :: proc(attributes: []^ast.Attribute) -> bool {
	for name in attribute_names(attributes) {
		if name == "export" || name == "link_name" || strings.has_prefix(name, "deferred_") do return true
	}
	return false
}

has_attribute :: proc(attributes: []^ast.Attribute, name: string) -> bool {
	return slice.contains(attribute_names(attributes), name)
}

attribute_names :: proc(attributes: []^ast.Attribute) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for attribute in attributes {
		for elem in attribute.elems {
			#partial switch e in elem.derived {
			case ^ast.Ident:
				append(&names, e.name)
			case ^ast.Field_Value:
				field := e.field.derived.(^ast.Ident) or_continue
				append(&names, field.name)
			}
		}
	}
	return names[:]
}
