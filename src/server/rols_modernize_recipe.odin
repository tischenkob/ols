#+private file

package server

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:sync"

import "src:common"

// User-defined rewrites from the `modernize_recipes` config key. Each recipe is the rule
// `recipe/<name>` of family `recipe`, in the default set. Only `ols query modernize` runs them.
//
// `match` is Odin source with `$name` metavariables. One expression statement is an expression
// pattern and matches any expression; anything else is a statement-sequence pattern and matches
// consecutive statements of a block. `replace` is Odin source too: each `$name` becomes the code
// text the metavariable bound, in parentheses when it is a compound expression in operand position.

@(private = "package")
Recipe_Set :: struct {
	recipes: []Recipe,
	errors:  []string, // "recipe <name>: <problem>", one per skipped recipe
	rules:   []Modernize_Rule, // the built-in rules, then one per recipe
}

Recipe :: struct {
	id:        string, // recipe/<name>
	name:      string,
	vars:      []string, // metavariables of match, as reserved identifiers
	call_vars: []string, // metavariables used once in match and once in replace
	expr:      ^ast.Node, // expression pattern, else nil
	stmts:     []^ast.Stmt, // statement-sequence pattern
	root:      typeid, // node kind of expr or stmts[0]
	callee:    string, // last name of the callee when expr is a call
	template:  string, // replace, metavariables renamed
	holes:     []Hole, // sorted by start
	imports:   []string,
	wheres:    []Where,
}

// A placeholder or a package qualifier in the template.
Hole :: struct {
	start, end: int,
	name:       string,
	var:        bool, // a metavariable, else a package qualifier
	operand:    bool, // the operand of an operator, selector, index, call or cast
}

WHERE_KINDS :: []string{"slice", "dynamic_array", "fixed_array", "map", "string", "pointer"}

Where :: struct {
	var:  string, // as a reserved identifier
	kind: string, // one of WHERE_KINDS
}

NAME_CHARS :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."

// `$name` is a polymorphic type to the parser, so the source renames it before parsing.
METAVAR_PREFIX :: "__rw_"
WRAP_PREFIX :: "package p\n_ :: proc() {\n"
WRAP_SUFFIX :: "\n}\n"

// Parsed sets by the text of the recipes that produced them. They live on the heap for the life
// of the process: the CLI loads one, the tests a few.
sets: map[string]^Recipe_Set
sets_mutex: sync.Mutex

// nil without recipes. The parse runs once per distinct recipe list.
@(private = "package")
modernize_recipe_set :: proc(config: ^common.Config) -> ^Recipe_Set {
	if len(config.modernize_recipes) == 0 do return nil
	key := fmt.tprint(config.modernize_recipes)

	sync.mutex_lock(&sets_mutex)
	defer sync.mutex_unlock(&sets_mutex)
	if set, ok := sets[key]; ok do return set

	context.allocator = runtime.heap_allocator()
	set := new(Recipe_Set)
	set^ = parse_recipes(config.modernize_recipes)
	sets[strings.clone(key)] = set
	return set
}

parse_recipes :: proc(configured: []common.Modernize_Recipe) -> Recipe_Set {
	recipes := make([dynamic]Recipe)
	errors := make([dynamic]string)
	rules := slice.clone_to_dynamic(modernize_builtin_rules())
	names := make(map[string]struct{}, context.temp_allocator)

	for config, i in configured {
		if config.name == "" || strings.trim(config.name, NAME_CHARS) != "" {
			append(
				&errors,
				fmt.aprintf("recipe %d: name %q must be letters, digits, '-', '_' or '.'", i + 1, config.name),
			)
			continue
		}
		if config.name in names {
			append(&errors, fmt.aprintf("recipe %s: another recipe has this name", config.name))
			continue
		}
		names[config.name] = {}
		recipe, problem := parse_recipe(config)
		if problem != "" {
			append(&errors, fmt.aprintf("recipe %s: %s", config.name, problem))
			continue
		}
		append(&recipes, recipe)
		append(&rules, Modernize_Rule{recipe.id, "recipe", true})
	}
	return {recipes[:], errors[:], rules[:]}
}

// problem is empty when the recipe is usable.
parse_recipe :: proc(config: common.Modernize_Recipe) -> (recipe: Recipe, problem: string) {
	recipe.name = strings.clone(config.name)
	recipe.id = strings.concatenate({"recipe/", config.name})
	recipe.imports = common.clone_string_list(config.imports)
	for path in recipe.imports {
		if import_path_name(path) == "" do return {}, fmt.tprintf("import %q has no package name", path)
	}

	match_text: string
	match_text, problem = rename_metavars(strings.trim_space(config.match))
	if problem != "" do return {}, problem
	match_stmts: []^ast.Stmt
	match_shift: int
	match_stmts, match_shift, problem = parse_snippet(match_text, "match")
	if problem != "" do return {}, problem
	if len(match_stmts) == 0 do return {}, "match is empty"

	match_counts := make(map[string]int, context.temp_allocator)
	vars := make([dynamic]string)
	for stmt in match_stmts {
		count_metavars(stmt, &match_counts)
	}
	for name in match_counts do append(&vars, name)
	slice.sort(vars[:])
	recipe.vars = vars[:]
	if problem = check_snippet(match_stmts, false); problem != "" do return {}, problem

	// The matcher must accept the pattern as code, else the recipe could never fire.
	// Node offsets count from the start of the text parse_snippet parsed.
	self := pattern_matcher_make(strings.concatenate({WRAP_PREFIX, match_shift > 0 ? EXPR_PREFIX : "", match_text}))
	self.vars = recipe.vars
	self.call_vars = recipe.vars
	if !pattern_match_stmts(&self, match_stmts, match_stmts) {
		if self.unsupported == nil do return {}, "match has a typed declaration or a tagged literal or type, which matching does not support"
		kind := fmt.tprint(reflect.union_variant_typeid(self.unsupported.derived))
		return {}, fmt.tprintf("%s is not supported in match", strings.trim_left(kind[strings.last_index_byte(kind, '.') + 1:], "^"))
	}

	if expr_stmt, is_expr := match_stmts[0].derived.(^ast.Expr_Stmt); is_expr && len(match_stmts) == 1 {
		recipe.expr = pattern_unparen(expr_stmt.expr)
		if _, is_ident := recipe.expr.derived.(^ast.Ident); is_ident {
			return {}, "match is a lone name, which matches declarations and fields too"
		}
		recipe.root = reflect.union_variant_typeid(recipe.expr.derived)
		if call, is_call := recipe.expr.derived.(^ast.Call_Expr); is_call {
			recipe.callee = callee_name(call)
			if is_metavar(recipe.callee) do recipe.callee = ""
		}
	} else {
		recipe.stmts = match_stmts
		recipe.root = reflect.union_variant_typeid(match_stmts[0].derived)
	}

	template: string
	template, problem = rename_metavars(strings.trim_space(config.replace))
	if problem != "" do return {}, problem
	replace_stmts: []^ast.Stmt
	shift: int
	replace_stmts, shift, problem = parse_snippet(template, "replace")
	if problem != "" do return {}, problem
	if recipe.expr != nil {
		is_expr := false
		if len(replace_stmts) == 1 {
			_, is_expr = replace_stmts[0].derived.(^ast.Expr_Stmt)
		}
		if !is_expr do return {}, "replace must be one expression, as match is"
	}
	if problem = check_snippet(replace_stmts, true); problem != "" do return {}, problem
	recipe.template = template

	holes := Holes {
		base     = len(WRAP_PREFIX) + shift,
		out      = make([dynamic]Hole),
		operands = make(map[uintptr]struct{}, context.temp_allocator),
		counts   = make(map[string]int, context.temp_allocator),
	}
	for stmt in replace_stmts {
		collect_holes(stmt, &holes)
	}
	slice.sort_by(holes.out[:], proc(a, b: Hole) -> bool {return a.start < b.start})
	recipe.holes = holes.out[:]
	for name in holes.counts {
		if name not_in match_counts do return {}, fmt.tprintf("replace uses $%s, which match does not bind", name[len(METAVAR_PREFIX):])
	}

	// A binding with a call keeps its evaluation count only when the rewrite writes it once.
	call_vars := make([dynamic]string)
	for name in recipe.vars {
		if match_counts[name] == 1 && holes.counts[name] == 1 do append(&call_vars, name)
	}
	recipe.call_vars = call_vars[:]

	wheres := make([dynamic]Where)
	for w in config.where_ {
		var := strings.concatenate({METAVAR_PREFIX, w.var})
		if var not_in match_counts do return {}, fmt.tprintf("where names $%s, which match does not bind", w.var)
		if !slice.contains(WHERE_KINDS, w.kind) {
			return {}, fmt.tprintf("where kind %q is not slice, dynamic_array, fixed_array, map, string or pointer", w.kind)
		}
		append(&wheres, Where{var, strings.clone(w.kind)})
	}
	recipe.wheres = wheres[:]
	return recipe, ""
}

// A metavariable in the field of a selector, such as $f in `$x.$f` or `.$f`, can never match.
// In replace, lines after the first get the indentation of the matched code, which would change
// a string literal that spans lines.
check_snippet :: proc(stmts: []^ast.Stmt, is_replace: bool) -> string {
	Check :: struct {
		is_replace: bool,
		problem:    string,
	}
	check := Check{is_replace, ""}
	visitor := ast.Visitor {
		data = &check,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			check := (^Check)(visitor.data)
			if node == nil || check.problem != "" do return nil
			field: ^ast.Ident
			#partial switch n in node.derived {
			case ^ast.Selector_Expr:
				field = n.field
			case ^ast.Implicit_Selector_Expr:
				field = n.field
			case ^ast.Basic_Lit:
				if check.is_replace && strings.contains_rune(n.tok.text, '\n') {
					check.problem = "replace has a string literal that spans lines"
				}
			}
			if field != nil && is_metavar(field.name) {
				check.problem = fmt.tprintf(
					"$%s names a field, which a metavariable cannot match",
					field.name[len(METAVAR_PREFIX):],
				)
			}
			return visitor
		},
	}
	for stmt in stmts do ast.walk(&visitor, stmt)
	return check.problem
}

is_metavar :: proc(name: string) -> bool {
	return strings.has_prefix(name, METAVAR_PREFIX)
}

callee_name :: proc(call: ^ast.Call_Expr) -> string {
	#partial switch callee in pattern_unparen(call.expr).derived {
	case ^ast.Ident:
		return callee.name
	case ^ast.Selector_Expr:
		if callee.field != nil do return callee.field.name
	}
	return ""
}

// Renames `$name` to the reserved identifier outside string and rune literals and comments.
rename_metavars :: proc(text: string) -> (string, string) {
	if strings.contains(text, METAVAR_PREFIX) do return "", "the " + METAVAR_PREFIX + " prefix is reserved for metavariables"
	b := strings.builder_make()
	quote: byte
	depth := 0 // nested block comments
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		next: byte = i + 1 < len(text) ? text[i + 1] : 0
		switch {
		case depth > 0:
			if c == '*' && next == '/' {
				depth -= 1
				strings.write_byte(&b, c)
				i += 1
				c = next
			} else if c == '/' && next == '*' {
				depth += 1
				strings.write_byte(&b, c)
				i += 1
				c = next
			}
		case quote != 0:
			if c == '\\' && quote != '`' && next != 0 {
				strings.write_byte(&b, c)
				i += 1
				c = next
			} else if c == quote {
				quote = 0
			}
		case c == '"' || c == '\'' || c == '`':
			quote = c
		case c == '/' && next == '/':
			end := strings.index_byte(text[i:], '\n')
			end = end < 0 ? len(text) : i + end
			strings.write_string(&b, text[i:end])
			i = end - 1
			continue
		case c == '/' && next == '*':
			depth = 1
			strings.write_byte(&b, c)
			i += 1
			c = next
		case c == '$':
			if next == '_' || ('a' <= next && next <= 'z') || ('A' <= next && next <= 'Z') {
				strings.write_string(&b, METAVAR_PREFIX)
				continue
			}
			return "", "`$` must start a metavariable name"
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b), ""
}

@(thread_local)
first_error: string

capture_error :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	if first_error == "" {
		first_error = fmt.tprintf("line %d: %s", pos.line - 2, fmt.tprintf(msg, ..args))
	}
}

// The statements of text as the body of a procedure. Text that parses as the value of `_ = ` is
// one expression, since `T{x}` or `cast(T)x` would not parse as that statement on its own. The
// expression comes back as an expression statement whose offsets are shift bytes further into the
// parsed text than the text's own.
parse_snippet :: proc(text, what: string) -> (stmts: []^ast.Stmt, shift: int, problem: string) {
	// A leading brace is a block statement, never a compound literal without a type.
	if strings.has_prefix(text, "{") {
		stmts, problem = parse_body(text, what)
		return
	}
	if value, value_problem := parse_body(strings.concatenate({EXPR_PREFIX, text}), what);
	   value_problem == "" && len(value) == 1 {
		if assign, is_assign := value[0].derived.(^ast.Assign_Stmt);
		   is_assign && len(assign.rhs) == 1 && len(assign.lhs) == 1 {
			stmt := ast.new(ast.Expr_Stmt, assign.rhs[0].pos, assign.rhs[0].end)
			stmt.expr = assign.rhs[0]
			stmts = make([]^ast.Stmt, 1)
			stmts[0] = stmt
			return stmts, len(EXPR_PREFIX), ""
		}
	}
	stmts, problem = parse_body(text, what)
	return
}

EXPR_PREFIX :: "_ = "

parse_body :: proc(text, what: string) -> (stmts: []^ast.Stmt, problem: string) {
	p := parser.Parser {
		err   = capture_error,
		flags = {.Optional_Semicolons},
	}
	file := new(ast.File)
	file.fullpath = "recipe.odin"
	file.src = strings.concatenate({WRAP_PREFIX, text, WRAP_SUFFIX})
	first_error = ""
	if !parse_file(&p, file) || file.syntax_error_count > 0 || len(file.decls) != 1 {
		if first_error == "" do first_error = "it is not a procedure body"
		return nil, fmt.tprintf("%s does not parse: %s", what, first_error)
	}
	if decl, is_decl := file.decls[0].derived.(^ast.Value_Decl); is_decl && len(decl.values) == 1 {
		if lit, is_lit := decl.values[0].derived.(^ast.Proc_Lit); is_lit && lit.body != nil {
			if block, is_block := lit.body.derived.(^ast.Block_Stmt); is_block do return block.stmts, ""
		}
	}
	return nil, fmt.tprintf("%s does not parse as statements", what)
}

count_metavars :: proc(root: ^ast.Node, counts: ^map[string]int) {
	visitor := ast.Visitor {
		data = counts,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			if ident, ok := node.derived.(^ast.Ident); ok && is_metavar(ident.name) {
				counts := (^map[string]int)(visitor.data)
				counts[ident.name] += 1
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
}

Holes :: struct {
	base:     int, // offset of the template in the parsed text
	out:      [dynamic]Hole,
	operands: map[uintptr]struct{}, // nodes in operand position, found at their parent
	counts:   map[string]int, // metavariable uses
}

collect_holes :: proc(root: ^ast.Node, holes: ^Holes) {
	visitor := ast.Visitor {
		data = holes,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			holes := (^Holes)(visitor.data)
			operands: []^ast.Expr
			#partial switch n in node.derived {
			case ^ast.Ident:
				if is_metavar(n.name) {
					holes.counts[n.name] += 1
					append(
						&holes.out,
						Hole {
							n.pos.offset - holes.base,
							n.end.offset - holes.base,
							n.name,
							true,
							uintptr(node) in holes.operands,
						},
					)
				}
			case ^ast.Selector_Expr:
				operands = {n.expr}
				if ident, ok := n.expr.derived.(^ast.Ident); ok && !is_metavar(ident.name) {
					start := ident.pos.offset - holes.base
					append(&holes.out, Hole{start, start + len(ident.name), ident.name, false, false})
				}
			case ^ast.Binary_Expr:
				operands = {n.left, n.right}
			case ^ast.Unary_Expr:
				operands = {n.expr}
			case ^ast.Index_Expr:
				operands = {n.expr}
			case ^ast.Slice_Expr:
				operands = {n.expr}
			case ^ast.Call_Expr:
				operands = {n.expr}
			case ^ast.Deref_Expr:
				operands = {n.expr}
			case ^ast.Or_Else_Expr:
				operands = {n.x, n.y}
			case ^ast.Or_Return_Expr:
				operands = {n.expr}
			case ^ast.Or_Branch_Expr:
				operands = {n.expr}
			case ^ast.Ternary_If_Expr:
				operands = {n.x, n.cond, n.y}
			case ^ast.Ternary_When_Expr:
				operands = {n.x, n.cond, n.y}
			case ^ast.Type_Cast:
				operands = {n.expr}
			case ^ast.Auto_Cast:
				operands = {n.expr}
			case ^ast.Type_Assertion:
				operands = {n.expr}
			}
			for operand in operands do if operand != nil do holes.operands[uintptr(operand)] = {}
			return visitor
		},
	}
	ast.walk(&visitor, root)
}

// An expression that binds tighter than any operator, so it needs no parentheses as an operand.
is_primary :: proc(node: ^ast.Node) -> bool {
	#partial switch _ in node.derived {
	case ^ast.Binary_Expr,
	     ^ast.Unary_Expr,
	     ^ast.Ternary_If_Expr,
	     ^ast.Ternary_When_Expr,
	     ^ast.Or_Else_Expr,
	     ^ast.Or_Return_Expr,
	     ^ast.Or_Branch_Expr,
	     ^ast.Type_Cast,
	     ^ast.Auto_Cast:
		return false
	}
	return true
}

Walker :: struct {
	document: ^Document,
	src:      string,
	recipes:  []^Recipe,
	matcher:  Pattern_Matcher,
	out:      [dynamic]Modernize_Fix,
}

// The fixes of every selected recipe, overlapping ones included.
@(private = "package")
recipe_fixes :: proc(document: ^Document, set: ^Recipe_Set, selected: map[string]struct{}) -> []Modernize_Fix {
	w := Walker {
		document = document,
		src      = document.ast.src,
		matcher  = pattern_matcher_make(document.ast.src),
		out      = make([dynamic]Modernize_Fix, context.temp_allocator),
	}
	w.matcher.imports = document.ast.imports[:]
	w.matcher.match_imports = true
	w.matcher.guard_control_flow = true
	recipes := make([dynamic]^Recipe, context.temp_allocator)
	for &recipe in set.recipes do if recipe.id in selected do append(&recipes, &recipe)
	if len(recipes) == 0 do return nil
	w.recipes = recipes[:]

	visitor := ast.Visitor {
		data = &w,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			w := (^Walker)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.Block_Stmt:
				scan_stmts(w, n.stmts)
			case ^ast.Case_Clause:
				scan_stmts(w, n.body)
			case ^ast.Paren_Expr:
				// The inner expression is visited on its own.
				return visitor
			}
			kind := reflect.union_variant_typeid(node.derived)
			callee := ""
			if call, is_call := node.derived.(^ast.Call_Expr); is_call do callee = callee_name(call)
			for recipe in w.recipes {
				if recipe.expr == nil || recipe.root != kind do continue
				if recipe.callee != "" && recipe.callee != callee do continue
				begin(w, recipe)
				if pattern_match(&w.matcher, recipe.expr, node) {
					add_fix(w, recipe, node.pos.offset, node.end.offset)
				}
			}
			return visitor
		},
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	return w.out[:]
}

scan_stmts :: proc(w: ^Walker, stmts: []^ast.Stmt) {
	for i := 0; i < len(stmts); {
		step := 1
		kind := reflect.union_variant_typeid(stmts[i].derived)
		for recipe in w.recipes {
			n := len(recipe.stmts)
			if n == 0 || n > len(stmts) - i || recipe.root != kind do continue
			begin(w, recipe)
			if !pattern_match_stmts(&w.matcher, recipe.stmts, stmts[i:][:n]) do continue
			if add_fix(w, recipe, stmts[i].pos.offset, stmts[i + n - 1].end.offset) {
				step = n
				break
			}
		}
		i += step
	}
}

begin :: proc(w: ^Walker, recipe: ^Recipe) {
	w.matcher.vars = recipe.vars
	w.matcher.call_vars = recipe.call_vars
	pattern_reset(&w.matcher)
}

// Checks the match the matcher holds and appends its fix; false when the match is refused.
add_fix :: proc(w: ^Walker, recipe: ^Recipe, start, end: int) -> bool {
	m := &w.matcher

	// Two bindings with calls or control flow could change their evaluation order.
	calls := 0
	for _, node in m.binds do if pattern_has_effect(node, true) do calls += 1
	if calls > 1 do return false

	// A comment survives only inside a binding the replacement writes.
	for group in w.document.ast.comments {
		comments: for comment in group.list {
			at := comment.pos.offset
			if at < start || at >= end do continue
			for hole in recipe.holes {
				if !hole.var do continue
				bound := m.binds[hole.name]
				if bound.pos.offset <= at && at + len(comment.text) <= bound.end.offset do continue comments
			}
			return false
		}
	}

	// A qualifier of match must still name the import where the fix goes.
	for _, name in m.qualifiers {
		for imp in w.document.ast.imports {
			if pattern_import_name(imp) == name && name_taken(w.document, start, name, strings.trim(imp.fullpath, "\"")) do return false
		}
	}

	for where_ in recipe.wheres {
		if !where_holds(w.document, m.binds[where_.var], where_.kind) do return false
	}

	// Each recipe import goes in under the name the file already uses, else its own name.
	qualifiers := make(map[string]string, context.temp_allocator)
	missing := make([dynamic]string, context.temp_allocator)
	for path in recipe.imports {
		alias, imported := import_alias(w.document, path)
		name := alias if alias != "" else import_path_name(path)
		if name_taken(w.document, start, name, path) do return false
		qualifiers[import_path_name(path)] = name
		if !imported do append(&missing, path)
	}

	line_start := strings.last_index_byte(w.src[:start], '\n') + 1
	indent_end := line_start
	for indent_end < start && (w.src[indent_end] == '\t' || w.src[indent_end] == ' ') do indent_end += 1
	indent := w.src[line_start:indent_end]

	b := strings.builder_make(context.temp_allocator)
	at := 0
	for hole in recipe.holes {
		write_template(&b, recipe.template[at:hole.start], indent)
		at = hole.end
		if hole.var {
			bound := m.binds[hole.name]
			text := node_text(w.src, bound)
			if hole.operand && !is_primary(bound) {
				fmt.sbprintf(&b, "(%s)", text)
			} else {
				strings.write_string(&b, text)
			}
		} else if name, ok := m.qualifiers[hole.name]; ok {
			strings.write_string(&b, name)
		} else if name, ok = qualifiers[hole.name]; ok {
			strings.write_string(&b, name)
		} else {
			strings.write_string(&b, hole.name)
		}
	}
	write_template(&b, recipe.template[at:], indent)

	append(
		&w.out,
		Modernize_Fix {
			rule = recipe.id,
			title = fmt.tprintf("Apply recipe %s", recipe.name),
			start = start,
			end = end,
			text = strings.to_string(b),
			imports = missing[:],
		},
	)
	return true
}

// Template lines after the first take the indentation of the matched code.
write_template :: proc(b: ^strings.Builder, text, indent: string) {
	text := text
	for {
		newline := strings.index_byte(text, '\n')
		if newline < 0 do break
		strings.write_string(b, text[:newline + 1])
		strings.write_string(b, indent)
		text = text[newline + 1:]
	}
	strings.write_string(b, text)
}

// Only names and selectors have a resolved type, so any other binding fails the constraint.
where_holds :: proc(document: ^Document, node: ^ast.Node, kind: string) -> bool {
	if node == nil do return false
	#partial switch _ in node.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
	case:
		return false
	}
	resolved, ok := resolve_entire_file(document)[uintptr(node)]
	if !ok || resolved.is_unresolved || resolved.symbol == nil do return false
	symbol := resolved.symbol
	if kind == "pointer" do return symbol.pointers > 0
	if symbol.pointers > 0 do return false
	#partial switch v in symbol.value {
	case SymbolSliceValue:
		return kind == "slice"
	case SymbolDynamicArrayValue:
		return kind == "dynamic_array"
	case SymbolFixedArrayValue:
		return kind == "fixed_array"
	case SymbolMapValue:
		return kind == "map"
	case SymbolBasicValue:
		return kind == "string" && v.ident != nil && v.ident.name == "string"
	}
	return false
}
