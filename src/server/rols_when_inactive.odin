package server

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

import "src:common"

// The files of a package directory, whose constants inactive_when_decls reads besides those of the evaluated file.
// The table is built on first use, in allocator, from the files that the evaluated target builds and that share
// the `package` clause of the first file that needs it.
When_Package :: struct {
	files:     []string,
	allocator: mem.Allocator,
	built:     bool,
	pkg_name:  string,
	// The constants outside any `when` of those files, by name.
	plain:     map[string]^ast.Expr,
	// The tables of the packages that the files import, by directory, built on first use in allocator.
	imported:  map[string]^When_Package,
	// For an imported package, its plain constants folded, in the temp allocator.
	consts:    map[string]When_Expr,
}

// The value declarations of file in a `when` branch that the editor's target does not build. The conditions
// evaluate as the editor evaluates them: ODIN_OS and ODIN_ARCH for the target of set_when_target, else the profile
// os and arch, else the host, the builtins that set_when_target seeds, `#config(NAME, default)` from the `-define:`
// values of set_when_target, then the profile defines, then the default, the constants of the file, or of every
// file of pkg when given, and a selector alias.NAME to a constant outside any `when` of the package that the file
// imports as alias, found through the collections of set_when_target or relative to the file. Only `!`,
// comparisons, `&&` and `||` fold; other operators count as unknown. The evaluator reads a name it does not know as
// false, so a chain counts only up to its first condition with such a name, such as an unseeded ODIN_DEBUG or
// ODIN_TEST or a name that the other package does not declare: that branch and the ones after it are not reported.
// A define reaches only `#config`, as odin passes it, not a bare name as the editor's profile defines do. Allocates
// in context.allocator.
inactive_when_decls :: proc(file: ^ast.File, pkg: ^When_Package = nil) -> map[^ast.Value_Decl]struct{} {
	inactive := make(map[^ast.Value_Decl]struct{})
	// The walk below reaches `when` statements at file scope and in foreign blocks.
	has_when := false
	for decl in file.decls {
		#partial switch d in decl.derived {
		case ^ast.When_Stmt:
			has_when = true
		case ^ast.Foreign_Block_Decl:
			body := d.body.derived.(^ast.Block_Stmt) or_continue
			for stmt in body.stmts {
				if _, is_when := stmt.derived.(^ast.When_Stmt); is_when do has_when = true
			}
		}
	}
	if !has_when do return inactive

	ast_context := make_ast_context(file^, nil, file.pkg_name, "", file.fullpath, context.allocator)
	consts := seeded_when_consts()
	// The constants outside any `when`: one inside a branch may come from a branch that an unknown name chose.
	plain := make(map[string]^ast.Expr)
	add_plain_consts(&plain, file)
	add_selector_consts(&consts, &plain, file, pkg)
	// The package table costs a parse of the directory, so only a condition that another file can decide reads it.
	if pkg != nil && needs_package(file.decls[:], plain) {
		if !pkg.built do build_when_package(pkg, file.pkg_name)
		if pkg.pkg_name == file.pkg_name {
			for name, value in pkg.plain {
				// A selector in another file names an import of that file, which may differ from this one's.
				if name not_in plain && !has_when_selector(value) do plain[name] = value
			}
		}
	}
	// walk_when_decls trusts only the conditions whose when_kind is known, and the fold gives each constant that
	// such a condition reads the value that it reads with every constant in view.
	fold_when_consts(&consts, plain)
	get_globals(file^, &ast_context)
	register_when_consts_from_globals(&consts, ast_context.globals)
	for decl in file.decls {
		walk_when_decls(decl, consts, plain, &inactive)
	}
	return inactive
}

// The names that each `when` evaluation of this thread starts from: the builtins that set_when_target seeds. A
// define is not among them: odin reads it only through `#config`, which resolve_config_directive evaluates.
@(private = "file")
seeded_when_consts :: proc() -> map[string]When_Expr {
	consts := make(map[string]When_Expr, context.temp_allocator)
	for value, builtin in when_builtins {
		if b, seeded := value.?; seeded do consts[fmt.tprint(builtin)] = b
	}
	return consts
}

// Adds each selector alias.NAME that a `when` condition of file or a constant of plain reads, where alias is an
// import of file, under its when_selector_key: to consts as the value of the constant NAME outside any `when` of
// the imported package, and to plain as a literal of that value for when_kind. A selector whose constant does not
// fold stays out, so it reads as unknown. The imported tables are kept in pkg when given.
@(private = "file")
add_selector_consts :: proc(
	consts: ^map[string]When_Expr,
	plain: ^map[string]^ast.Expr,
	file: ^ast.File,
	pkg: ^When_Package,
) {
	if len(file.imports) == 0 do return
	selectors := make([dynamic]^ast.Selector_Expr, context.temp_allocator)
	collect_cond_selectors(file.decls[:], plain^, &selectors)
	local: map[string]^When_Package
	cache := &pkg.imported if pkg != nil else &local
	allocator := pkg.allocator if pkg != nil else context.allocator
	for selector in selectors {
		alias := selector.expr.derived.(^ast.Ident).name
		key := when_selector_key(alias, selector.field.name)
		if key in plain do continue
		dir := import_dir(file, alias) or_continue
		imported, cached := cache[dir]
		if !cached {
			files, _ := filepath.glob(fmt.tprintf("%s/*.odin", dir), context.temp_allocator)
			imported = new_clone(When_Package{files = files, allocator = allocator}, allocator)
			build_when_package(imported, "")
			imported.consts = seeded_when_consts()
			fold_when_consts(&imported.consts, imported.plain)
			context.allocator = allocator
			cache[dir] = imported
		}
		value := imported.plain[selector.field.name] or_continue
		if when_kind(value, imported.plain, 0) == .Unknown do continue
		folded := resolve_when_expr(imported.consts, value) or_continue
		consts[key] = folded
		plain[key] = when_literal(folded, selector)
	}
}

// The directory of the package that file imports as alias: through a collection of set_when_target, or relative
// to the file. An unaliased import is named after its directory, as odin names it.
@(private = "file")
import_dir :: proc(file: ^ast.File, alias: string) -> (dir: string, ok: bool) {
	for imp in file.imports {
		if len(imp.fullpath) < 2 do continue
		import_path := imp.fullpath[1:len(imp.fullpath) - 1]
		if colon := strings.index_byte(import_path, ':'); colon > 0 {
			root := when_collections[import_path[:colon]] or_continue
			dir, _ = filepath.join({root, import_path[colon + 1:]}, context.temp_allocator)
		} else {
			dir, _ = filepath.join({filepath.dir(file.fullpath), import_path}, context.temp_allocator)
		}
		name := imp.name.text if imp.name.text != "" else filepath.base(dir)
		if name == alias do return dir, true
	}
	return "", false
}

// A literal that when_kind and resolve_when_expr read as value, at the position of at. A string, such as an
// ODIN_OS value or a string constant, compares by its text, as an implicit selector does.
@(private = "file")
when_literal :: proc(value: When_Expr, at: ^ast.Node) -> ^ast.Expr {
	#partial switch v in value {
	case bool:
		ident := ast.new(ast.Ident, at.pos, at.end)
		ident.name = "true" if v else "false"
		return ident
	case int:
		lit := ast.new(ast.Basic_Lit, at.pos, at.end)
		lit.tok.kind = .Integer
		lit.tok.text = fmt.aprint(v)
		return lit
	case string:
		selector := ast.new(ast.Implicit_Selector_Expr, at.pos, at.end)
		selector.field = ast.new(ast.Ident, at.pos, at.end)
		selector.field.name = v
		return selector
	}
	return ast.new(ast.Bad_Expr, at.pos, at.end)
}

// Appends the selectors that the `when` conditions among stmts read, nested ones included, directly or through
// the constants of plain.
@(private = "file")
collect_cond_selectors :: proc(
	stmts: []^ast.Stmt,
	plain: map[string]^ast.Expr,
	selectors: ^[dynamic]^ast.Selector_Expr,
) {
	for stmt in stmts {
		if stmt == nil do continue
		#partial switch s in stmt.derived {
		case ^ast.Block_Stmt:
			collect_cond_selectors(s.stmts[:], plain, selectors)
		case ^ast.Foreign_Block_Decl:
			collect_cond_selectors({s.body}, plain, selectors)
		case ^ast.When_Stmt:
			collect_when_selectors(s.cond, plain, selectors, 0)
			collect_cond_selectors({s.body, s.else_stmt}, plain, selectors)
		}
	}
}

// Appends the selectors pkg.NAME, with an identifier pkg, among the operands of expr that when_kind reads, and
// among those of the constants of plain that expr names, so that only a selector that a condition can reach builds
// a package.
@(private = "file")
collect_when_selectors :: proc(
	expr: ^ast.Expr,
	plain: map[string]^ast.Expr,
	selectors: ^[dynamic]^ast.Selector_Expr,
	depth: int,
) {
	if expr == nil || depth > 8 do return
	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		collect_when_selectors(e.expr, plain, selectors, depth)
	case ^ast.Ident:
		collect_when_selectors(plain[e.name] or_else nil, plain, selectors, depth + 1)
	case ^ast.Unary_Expr:
		collect_when_selectors(e.expr, plain, selectors, depth)
	case ^ast.Binary_Expr:
		collect_when_selectors(e.left, plain, selectors, depth)
		collect_when_selectors(e.right, plain, selectors, depth)
	case ^ast.Call_Expr:
		if len(e.args) == 2 do collect_when_selectors(e.args[1], plain, selectors, depth)
	case ^ast.Selector_Expr:
		if _, is_ident := e.expr.derived.(^ast.Ident); is_ident do append(selectors, e)
	}
}

// Whether expr reads a selector among its own operands that when_kind reads.
@(private = "file")
has_when_selector :: proc(expr: ^ast.Expr) -> bool {
	selectors := make([dynamic]^ast.Selector_Expr, context.temp_allocator)
	collect_when_selectors(expr, nil, &selectors, 0)
	return len(selectors) > 0
}

// The target that set_when_target chose for the `when` evaluation of this thread, which resolve_when_ident and
// host_target read before the profile. Thread-local, so a CLI query in a test does not move other tests' targets.
@(thread_local)
when_target: Maybe(parser.Build_Target)

// The builtin bool constants that the odin command line decides, named as in the source.
When_Builtin :: enum {
	ODIN_DEBUG,
	ODIN_TEST,
	ODIN_DISABLE_ASSERT,
	ODIN_NO_BOUNDS_CHECK,
}

// The values that set_when_target seeds for the builtins in the `when` evaluation of this thread. A nil value is
// unknown, as on the editor path.
@(thread_local)
when_builtins: [When_Builtin]Maybe(bool)

// The `-define:NAME=VALUE` values of checker_args that set_when_target seeds for the `when` evaluation of this
// thread, by NAME. They win over the profile defines, as odin's flags do: resolve_config_directive reads them first.
@(thread_local)
when_defines: map[string]string

// The collections by name, from the config that set_when_target read, through which a selector such as cfg.FLAG
// in a `when` condition finds the package that an import of a collection names.
@(thread_local)
when_collections: map[string]string

// The `when` evaluation state that set_when_target replaces and restore_when_target puts back.
When_Setting :: struct {
	target:      Maybe(parser.Build_Target),
	builtins:    [When_Builtin]Maybe(bool),
	defines:     map[string]string,
	collections: map[string]string,
}

// Points the `when` evaluation of this thread at the target of the checker_args of config: its `-target:`, else
// the host, as `odin check` and `odin test` build without a profile os. It seeds ODIN_DEBUG, ODIN_DISABLE_ASSERT
// and ODIN_NO_BOUNDS_CHECK from their flags in checker_args, ODIN_TEST as true when testing, else leaves it
// unknown, the `-define:NAME=VALUE` values of checker_args, the last one of a NAME winning, and the collections of
// config. It returns the previous state, which the caller passes to restore_when_target. The defines live in the
// temp allocator.
set_when_target :: proc(config: ^common.Config, testing := false) -> (saved: When_Setting) {
	saved = {when_target, when_builtins, when_defines, when_collections}
	when_target = base_target(config.checker_args)
	args := split_checker_args(config.checker_args)
	when_builtins = {}
	when_builtins[.ODIN_DEBUG] = slice.contains(args, "-debug")
	when_builtins[.ODIN_DISABLE_ASSERT] = slice.contains(args, "-disable-assert")
	when_builtins[.ODIN_NO_BOUNDS_CHECK] = slice.contains(args, "-no-bounds-check")
	if testing do when_builtins[.ODIN_TEST] = true
	when_defines = make(map[string]string, context.temp_allocator)
	for arg in args {
		define := strings.trim_prefix(arg, "-define:")
		if len(define) == len(arg) do continue
		if eq := strings.index_byte(define, '='); eq > 0 do when_defines[define[:eq]] = define[eq + 1:]
	}
	when_collections = config.collections
	return
}

// Puts back the `when` evaluation state that set_when_target returned.
restore_when_target :: proc(saved: When_Setting) {
	when_target = saved.target
	when_builtins = saved.builtins
	when_defines = saved.defines
	when_collections = saved.collections
}

// The target whose ODIN_OS and ODIN_ARCH the `when` conditions of this thread read before when_target, set while
// the lints walk a file that the host does not build, for the target that builds it. Unlike when_target, it leaves
// host_target alone, so the lookups of that file still find the declarations of its target (see rols_excluded.odin).
@(thread_local)
when_eval_target: Maybe(parser.Build_Target)

// The value of ODIN_OS or ODIN_ARCH under when_eval_target, else the target of set_when_target, spelled as
// resolve_when_ident spells it.
when_target_ident :: proc(ident: string) -> (value: When_Expr, ok: bool) {
	target, evaluated := when_eval_target.?
	if !evaluated do target = when_target.? or_return
	switch ident {
	case "ODIN_OS":
		return fmt.tprint(target.os), true
	case "ODIN_ARCH":
		return fmt.tprint(target.arch), true
	}
	return nil, false
}

// Fills the table of pkg from its files that the evaluated target builds and whose `package` clause is pkg_name.
// An empty pkg_name, for an imported package, takes the clause of the first such file that is not a `_test` one.
@(private = "file")
build_when_package :: proc(pkg: ^When_Package, pkg_name: string) {
	context.allocator = pkg.allocator
	pkg.built = true
	pkg.pkg_name = strings.clone(pkg_name)
	pkg.plain = make(map[string]^ast.Expr)
	target := host_target()
	for path in pkg.files {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil || !builds_on(path, string(data), target) do continue
		file, ok := parse_syntax(path, string(data))
		if !ok do continue
		if pkg.pkg_name == "" && !strings.has_suffix(file.pkg_name, "_test") do pkg.pkg_name = file.pkg_name
		if file.pkg_name == pkg.pkg_name do add_plain_consts(&pkg.plain, &file)
	}
}

// Whether a condition of the `when` statements among stmts, nested ones included, is unknown and names a constant
// that another file of the package may declare.
@(private = "file")
needs_package :: proc(stmts: []^ast.Stmt, plain: map[string]^ast.Expr) -> bool {
	for stmt in stmts {
		if stmt == nil do continue
		#partial switch s in stmt.derived {
		case ^ast.Block_Stmt:
			if needs_package(s.stmts[:], plain) do return true
		case ^ast.Foreign_Block_Decl:
			if needs_package({s.body}, plain) do return true
		case ^ast.When_Stmt:
			if when_kind(s.cond, plain, 0) != .Bool && names_missing_const(s.cond, plain, 0) do return true
			if needs_package({s.body, s.else_stmt}, plain) do return true
		}
	}
	return false
}

// Whether expr, or a constant of plain that it names, names a bare identifier that is neither in plain nor an
// ODIN_* builtin. A selector such as pkg.FLAG reads another package, so it does not count.
@(private = "file")
names_missing_const :: proc(expr: ^ast.Expr, plain: map[string]^ast.Expr, depth: int) -> bool {
	if expr == nil || depth > 8 do return false
	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		return names_missing_const(e.expr, plain, depth)
	case ^ast.Ident:
		if strings.has_prefix(e.name, "ODIN_") || e.name == "true" || e.name == "false" do return false
		value, is_plain := plain[e.name]
		return !is_plain || names_missing_const(value, plain, depth + 1)
	case ^ast.Call_Expr:
		return len(e.args) == 2 && names_missing_const(e.args[1], plain, depth)
	case ^ast.Unary_Expr:
		return names_missing_const(e.expr, plain, depth)
	case ^ast.Binary_Expr:
		return names_missing_const(e.left, plain, depth) || names_missing_const(e.right, plain, depth)
	}
	return false
}

// Adds the constants of file outside any `when` to plain, by name.
@(private = "package")
add_plain_consts :: proc(plain: ^map[string]^ast.Expr, file: ^ast.File) {
	for decl in file.decls {
		value_decl := decl.derived.(^ast.Value_Decl) or_continue
		if value_decl.is_mutable do continue
		for name, i in value_decl.names {
			ident := name.derived.(^ast.Ident) or_continue
			if i < len(value_decl.values) do plain[ident.name] = value_decl.values[i]
		}
	}
}

@(private = "file")
walk_when_decls :: proc(
	stmt: ^ast.Stmt,
	consts: map[string]When_Expr,
	plain: map[string]^ast.Expr,
	inactive: ^map[^ast.Value_Decl]struct{},
) {
	if stmt == nil do return
	#partial switch s in stmt.derived {
	case ^ast.Block_Stmt:
		for inner in s.stmts do walk_when_decls(inner, consts, plain, inactive)
	case ^ast.Foreign_Block_Decl:
		walk_when_decls(s.body, consts, plain, inactive)
	case ^ast.When_Stmt:
		// get_when_block_stmt reads an unknown name as false, so it decides only while every condition before
		// the active branch is known. Outside active_when_block, a selector reads the value that
		// add_selector_consts stored in consts.
		active, _ := get_when_block_stmt(s, consts)
		State :: enum {
			Searching,
			Unknown,
			Passed,
		}
		state := State.Searching
		for branch: ^ast.Stmt = s; branch != nil; {
			when_branch, is_when := branch.derived.(^ast.When_Stmt)
			body := when_branch.body if is_when else branch
			if state == .Searching && is_when && when_kind(when_branch.cond, plain, 0) != .Bool {
				state = .Unknown
			}
			block, is_block := body.derived.(^ast.Block_Stmt)
			if state == .Unknown || state == .Searching && is_block && block == active {
				walk_when_decls(body, consts, plain, inactive)
				if state == .Searching do state = .Passed
			} else {
				mark_when_decls(body, inactive)
			}
			branch = when_branch.else_stmt if is_when else nil
		}
	}
}

// Adds every value declaration under stmt to inactive.
@(private = "file")
mark_when_decls :: proc(stmt: ^ast.Stmt, inactive: ^map[^ast.Value_Decl]struct{}) {
	if stmt == nil do return
	#partial switch s in stmt.derived {
	case ^ast.Value_Decl:
		inactive[s] = {}
	case ^ast.Block_Stmt:
		for inner in s.stmts do mark_when_decls(inner, inactive)
	case ^ast.Foreign_Block_Decl:
		mark_when_decls(s.body, inactive)
	case ^ast.When_Stmt:
		mark_when_decls(s.body, inactive)
		mark_when_decls(s.else_stmt, inactive)
	}
}

// The kind of value that resolve_when_expr folds an expression to.
@(private = "file")
When_Kind :: enum {
	Unknown,
	Bool,
	Int,
	String,
}

// The kind of value that the when evaluator folds expr to, Unknown when it cannot fold it. A condition is known
// when its kind is Bool. The names it knows are ODIN_OS, ODIN_ARCH, the builtins that set_when_target seeds, the
// constants of plain whose kinds it knows in turn, and a selector that add_selector_consts added to plain. A
// `#config` call takes the kind of its `-define:` value, else its profile define, else its default.
// Only `!` of a bool, `&&` and `||` of bools, `==` and `!=` of the same kind and integer orderings fold, as in
// resolve_when_expr.
@(private = "file")
when_kind :: proc(expr: ^ast.Expr, plain: map[string]^ast.Expr, depth: int) -> When_Kind {
	if expr == nil || depth > 8 do return .Unknown
	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		return when_kind(e.expr, plain, depth)
	case ^ast.Ident:
		switch e.name {
		case "ODIN_OS", "ODIN_ARCH":
			return .String
		case "true", "false":
			return .Bool
		}
		if builtin, is_builtin := reflect.enum_from_name(When_Builtin, e.name); is_builtin {
			if when_builtins[builtin] != nil do return .Bool
		}
		value, is_plain := plain[e.name]
		return when_kind(value, plain, depth + 1) if is_plain else .Unknown
	case ^ast.Selector_Expr:
		base, is_ident := e.expr.derived.(^ast.Ident)
		if !is_ident do return .Unknown
		value, is_plain := plain[when_selector_key(base.name, e.field.name)]
		return when_kind(value, plain, depth + 1) if is_plain else .Unknown
	case ^ast.Basic_Lit:
		// A float, rune or imaginary literal reads as false.
		#partial switch e.tok.kind {
		case .Integer:
			return .Int if int_literal_fits(e.tok.text) else .Unknown
		case .String:
			return .String
		}
		return .Unknown
	case ^ast.Implicit_Selector_Expr:
		return .String
	case ^ast.Call_Expr:
		directive, is_directive := e.expr.derived.(^ast.Basic_Directive)
		if !is_directive || directive.name != "config" || len(e.args) != 2 do return .Unknown
		if name, is_ident := e.args[0].derived.(^ast.Ident); is_ident {
			value, defined := when_defines[name.name]
			if !defined do value, defined = common.config.profile.defines[name.name]
			if defined do return define_kind(value)
		}
		return when_kind(e.args[1], plain, depth)
	case ^ast.Unary_Expr:
		return .Bool if e.op.kind == .Not && when_kind(e.expr, plain, depth) == .Bool else .Unknown
	case ^ast.Binary_Expr:
		// The evaluator folds only comparisons and && or ||; arithmetic reads as false.
		left := when_kind(e.left, plain, depth)
		right := when_kind(e.right, plain, depth)
		if left == .Unknown || left != right do return .Unknown
		#partial switch e.op.kind {
		case .Cmp_And, .Cmp_Or:
			if left == .Bool do return .Bool
		case .Cmp_Eq, .Not_Eq:
			return .Bool
		case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
			if left == .Int do return .Bool
		}
	}
	return .Unknown
}

// Whether the integer text, a literal or a define with an optional sign, fits an int. strconv.parse_int, which the
// evaluator calls, wraps a larger one silently, so `18446744073709551616` reads as 0. The bound is max(int) for
// either sign, so min(int) itself counts as not fitting.
@(private = "file")
int_literal_fits :: proc(text: string) -> bool {
	text := text
	if len(text) > 1 && (text[0] == '-' || text[0] == '+') do text = text[1:]
	base: u128 = 10
	digits := text
	if len(text) > 2 && text[0] == '0' {
		switch text[1] {
		case 'b':
			base = 2
		case 'o':
			base = 8
		case 'z':
			base = 12
		case 'x':
			base = 16
		}
		if base != 10 || text[1] == 'd' do digits = text[2:]
	}
	value: u128
	for c in digits {
		digit: u128
		switch c {
		case '0' ..= '9':
			digit = u128(c - '0')
		case 'a' ..= 'z':
			digit = u128(c - 'a' + 10)
		case 'A' ..= 'Z':
			digit = u128(c - 'A' + 10)
		case:
			continue
		}
		value = value * base + digit
		if value > u128(max(int)) do return false
	}
	return true
}

// The kind of a define's value as resolve_config_directive folds it: an integer that fits an int, else a bool
// spelled as strconv.parse_bool reads it. Odin reads t, true, f and false in any case as bools, and other text as
// a string or a float, which the evaluator reads as false. A bool spelling that parse_bool rejects, such as `tRuE`,
// is unknown too, which leaves its branches unmarked.
@(private = "file")
define_kind :: proc(value: string) -> When_Kind {
	if _, is_int := strconv.parse_int(value); is_int && int_literal_fits(value) do return .Int
	_, is_bool := strconv.parse_bool(value)
	return .Bool if is_bool else .Unknown
}
