package server

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"
import "core:sync"

import "src:common"

// One edit a modernize rule proposes: bytes [start, end) of the document become text.
Modernize_Fix :: struct {
	rule:       string,
	title:      string,
	start, end: int,
	text:       string,
	imports:    []string, // import paths the text needs and the file lacks, like "core:slice"
}

// id is the diagnostic code, or `use-stdlib/<rule>` for the use_stdlib rules. Families:
// idiom: exact, behavior-preserving rewrites, the default set.
// review: fixes that delete code or can change behavior; they run only when --rule names them.
// migration: rewrites from deprecated or removed Odin forms to current ones; they have no lint.
// recipe: `recipe/<name>` for each `modernize_recipes` entry of the config, all default.
Modernize_Rule :: struct {
	id:      string,
	family:  string,
	default: bool,
}

Modernize_Applied :: struct {
	rule, title: string,
	pass:        int, // 1-based
	// 1-based, the column in bytes. Pass 1 positions are in the original text; a later pass
	// reports positions in the text the previous pass produced.
	line, col:   int,
}

Modernize_Result :: struct {
	text:         string,
	applied:      []Modernize_Applied,
	failed:       []string, // rules of a pass undone because its result did not parse
	converged:    bool, // no rule has anything left to change
	stalled:      bool, // every remaining fix contains the import insertion point, so none applies
	syntax_error: bool, // the input does not parse, so nothing ran
}

MODERNIZE_MAX_PASSES :: 8

// Table order is the tie priority when two fixes cover the same range. Stage by stage, new
// providers add their rules here.
@(private = "file")
simplify_rules := [?]Modernize_Rule {
	{"array-broadcast", "idiom", true},
	{"bool-return", "idiom", true},
	{"bool-compare", "idiom", true},
	{"double-negation", "idiom", true},
	{"bool-ternary", "idiom", true},
	{"redundant-parens", "idiom", true},
	{"full-slice", "idiom", true},
	{"for-true", "idiom", true},
	{"make-zero", "idiom", true},
	{"empty-else", "idiom", true},
	{"compound-assign", "idiom", true},
	{"nested-if", "idiom", true},
	{"range-loop", "idiom", true},
	{"or-else", "idiom", true},
	{"or-return", "idiom", true},
	{"or-break", "idiom", true},
	{"or-continue", "idiom", true},
	{"redundant-else", "idiom", true},
	{"trailing-return", "idiom", true},
}

// Lint fixes. unused-variable has two alternative fixes over one declaration, so each has its own
// id; when both run, the removal covers the discard and wins as the outer fix.
@(private = "file")
lint_rules := [?]Modernize_Rule {
	{"redundant-partial", "idiom", true},
	{"unnecessary-break", "idiom", true},
	{"replace-count", "idiom", true},
	{"unused-variable/remove", "review", false},
	{"unused-variable/discard", "review", false},
	{"unused-parameter", "review", false},
	{"unreachable-code", "review", false},
	{"self-assignment", "review", false},
	{"no-op-arithmetic", "review", false},
	{"append-no-values", "review", false},
	{"duplicate-import", "review", false},
	{"allocator-mismatch", "review", false},
	{"make-len-append", "review", false},
	{"missing-test-attribute", "review", false},
	{"range-off-by-one", "review", false},
}

@(private = "file")
cached_rules: []Modernize_Rule

@(private = "file")
cached_rules_once: sync.Once

// The built-in rules, then one per usable recipe of config.
modernize_rules :: proc(config: ^common.Config) -> []Modernize_Rule {
	if set := modernize_recipe_set(config); set != nil do return set.rules
	return modernize_builtin_rules()
}

// One line per configured recipe that does not run, in config order.
modernize_recipe_errors :: proc(config: ^common.Config) -> []string {
	set := modernize_recipe_set(config)
	return set.errors if set != nil else nil
}

modernize_builtin_rules :: proc() -> []Modernize_Rule {
	sync.once_do(&cached_rules_once, proc() {
		context.allocator = runtime.heap_allocator()
		rules := make([dynamic]Modernize_Rule)
		for rule in simplify_rules {
			append(&rules, rule)
		}
		for &rule in stdlib_rules() {
			exact := stdlib_rule_exact(rule.name)
			append(&rules, Modernize_Rule{stdlib_rule_id(&rule, context.allocator), exact ? "idiom" : "review", exact})
		}
		for rule in lint_rules {
			append(&rules, rule)
		}
		for rule in migration_rules {
			append(&rules, rule)
		}
		cached_rules = rules[:]
	})
	return cached_rules
}

// The use_stdlib matcher is syntactic, so a rule is exact only when the core call agrees with
// the hand-written code for every type and value it can match.
@(private = "file")
stdlib_rule_exact :: proc(name: string) -> bool {
	switch {
	case name == "copy_loop":
		// The loop panics on a short dst where copy stops early.
		return false
	case name == "clamp_if":
		// With lo > hi, clamp returns hi where the code returns lo.
		return false
	case strings.has_prefix(name, "max_"), strings.has_prefix(name, "min_"), strings.has_prefix(name, "abs_"):
		// Floats match too, and max, min and abs differ on NaN and -0.0.
		return false
	}
	return true
}

@(private = "file")
stdlib_rule_id :: proc(rule: ^Stdlib_Rule, allocator := context.temp_allocator) -> string {
	name, _ := strings.replace_all(rule.name, "_", "-", context.temp_allocator)
	return strings.concatenate({"use-stdlib/", name}, allocator)
}

// Rule ids and family names select rules; no tokens select the default set. unknown is the
// first token that names neither.
modernize_select :: proc(
	tokens: []string,
	config: ^common.Config,
	allocator := context.temp_allocator,
) -> (
	selected: map[string]struct{},
	unknown: string,
	ok: bool,
) {
	selected = make(map[string]struct{}, allocator)
	rules := modernize_rules(config)
	if len(tokens) == 0 {
		for rule in rules do if rule.default do selected[rule.id] = {}
		return selected, "", true
	}
	for token in tokens {
		token := strings.trim_space(token)
		known := false
		for rule in rules {
			if rule.id == token || rule.family == token {
				selected[rule.id] = {}
				known = true
			}
		}
		if !known do return selected, token, false
	}
	return selected, "", true
}

@(private = "file")
// Recipes come after every built-in rule, in config order: the sort is stable.
rule_priority :: proc(id: string) -> int {
	for rule, i in modernize_builtin_rules() do if rule.id == id do return i
	return max(int)
}

// The verdicts of `param_named_elsewhere` by procedure and parameter name, kept across the passes of one run.
// The reference search reads other files through the index, which matches the document only before the first
// pass rewrites it, so a later pass reuses a verdict and refuses a pair that it sees first.
Param_Verdicts :: struct {
	verdicts: map[Param_Key]bool,
	fresh:    bool, // the document holds the text the index was built from
}

Param_Key :: struct {
	procedure, param: string,
}

// The fixes of every selected rule, overlapping ones included. A provider runs only while its
// lint is enabled in the config, as in the editor. files, when given, replaces the workspace walk.
// verdicts caches the reference search of the unused-parameter fix.
modernize_fixes :: proc(
	document: ^Document,
	selected: map[string]struct{},
	config: ^common.Config,
	files: []Package_File = {},
	verdicts: ^Param_Verdicts,
) -> []Modernize_Fix {
	out := make([dynamic]Modernize_Fix, context.temp_allocator)

	if config.enable_lint_simplify {
		for s in simplifications(document) {
			if s.code not_in selected do continue
			append(&out, Modernize_Fix{rule = s.code, title = s.title, start = s.start, end = s.end, text = s.text})
		}
	}

	if config.enable_lint_use_stdlib {
		for m in stdlib_matches(document) {
			id := stdlib_rule_id(m.rule)
			if id not_in selected do continue
			// rols: the call replaces the whole range, so a comment inside would be deleted.
			if len(comments_overlapping(document.ast, m.start, m.end)) > 0 do continue
			fix := Modernize_Fix {
				rule  = id,
				title = fmt.tprintf("Replace with %s", m.name),
				start = m.start,
				end   = m.end,
			}
			alias := ""
			if m.pkg != "" {
				import_path := fmt.tprintf("core:%s", m.pkg)
				imported: bool
				alias, imported = import_alias(document, import_path)
				if name_taken(document, m.start, alias != "" ? alias : m.pkg, import_path) do continue
				if !imported {
					fix.imports = slice.clone([]string{import_path}, context.temp_allocator)
				}
			}
			fix.text = stdlib_rewrite(m, alias)
			append(&out, fix)
		}
	}

	wants_lint := false
	for rule in lint_rules do if rule.id in selected do wants_lint = true
	if wants_lint {
		for fix in lint_fixes(document, config, files) {
			if fix.code not_in selected do continue
			// The lint checks the named arguments of this file only; other files are searched as for the quick fix.
			if fix.code == "unused-parameter" {
				lit: ^ast.Proc_Lit
				for at in nodes_at(document.ast.decls[:], fix.start) {
					lit = at.node.derived.(^ast.Proc_Lit) or_else lit
				}
				name := document.ast.src[fix.start:fix.end]
				if lit == nil || judge_param(document, lit, name, files, verdicts) do continue
			}
			append(
				&out,
				Modernize_Fix{rule = fix.code, title = fix.title, start = fix.start, end = fix.end, text = fix.text},
			)
		}
	}

	wants_migration := false
	for rule in migration_rules do if rule.id in selected do wants_migration = true
	if wants_migration {
		append(&out, ..migration_fixes(document, selected))
	}

	if set := modernize_recipe_set(config); set != nil {
		append(&out, ..recipe_fixes(document, set, selected))
	}

	// A fix that would delete a comment is left out, whatever rule made it.
	kept := 0
	for fix in out {
		if fix_drops_comment(document.ast, fix.start, fix.end, fix.text) do continue
		out[kept] = fix
		kept += 1
	}
	return out[:kept]
}

// param_named_elsewhere through verdicts.
@(private = "file")
judge_param :: proc(
	document: ^Document,
	lit: ^ast.Proc_Lit,
	name: string,
	files: []Package_File,
	verdicts: ^Param_Verdicts,
) -> bool {
	decl, is_top := proc_decl_of(document, lit)
	// A procedure that is not top level is visible to its file only.
	if !is_top do return false
	key := Param_Key{final_name(decl.names[0]), name}
	if verdict, found := verdicts.verdicts[key]; found do return verdict
	if !verdicts.fresh do return true
	verdict := param_named_elsewhere(document, lit, name, files)
	// The names point into the text of this pass, which a later pass replaces.
	key.procedure = strings.clone(key.procedure, context.temp_allocator)
	key.param = strings.clone(key.param, context.temp_allocator)
	verdicts.verdicts[key] = verdict
	return verdict
}

// One pass: keeps the outermost of overlapping fixes, ties broken by rule order, adds the missing
// imports and reparses the document with the result. A fix around the import insertion point is
// left for a later pass. When the pass fails, the document goes back to its text before the pass.
// kept is sorted by start.
modernize_pass :: proc(
	document: ^Document,
	fixes: []Modernize_Fix,
	config: ^common.Config,
) -> (
	kept: []Modernize_Fix,
	text: string,
	ok: bool,
) {
	before := string(document.text[:document.used_text])

	sorted := slice.clone(fixes, context.temp_allocator)
	slice.stable_sort_by(sorted, proc(a, b: Modernize_Fix) -> bool {
		if a.start != b.start do return a.start < b.start
		if a.end != b.end do return a.end > b.end
		return rule_priority(a.rule) < rule_priority(b.rule)
	})
	chosen := make([dynamic]Modernize_Fix, context.temp_allocator)
	for fix in sorted {
		if len(chosen) > 0 && fix.start < chosen[len(chosen) - 1].end do continue
		append(&chosen, fix)
	}

	inserts := imports_insert(document, chosen[:])
	outside := make([dynamic]Modernize_Fix, context.temp_allocator)
	fixes: for fix in chosen {
		for insert in inserts do if fix.start < insert.start && insert.start < fix.end do continue fixes
		append(&outside, fix)
	}
	if len(outside) < len(chosen) {
		chosen = outside
		inserts = imports_insert(document, chosen[:])
	}
	edits := slice.clone_to_dynamic(chosen[:], context.temp_allocator)
	append(&edits, ..inserts)
	// An insertion goes before a replacement that starts at the same offset.
	slice.stable_sort_by(edits[:], proc(a, b: Modernize_Fix) -> bool {
		if a.start != b.start do return a.start < b.start
		return a.end < b.end
	})

	// The chosen fixes never overlap, so a failed splice is a bug; it counts as unparsable.
	spliced: bool
	if text, spliced = splice(before, edits[:]); !spliced {
		return chosen[:], before, false
	}
	if !reparse(document, text, config) {
		reparse(document, before, config)
		return chosen[:], before, false
	}
	return chosen[:], text, true
}

// Runs passes until no selected rule has a fix or MODERNIZE_MAX_PASSES passes ran. The document
// holds its original text again on return; the result text is in the temp allocator. files, when
// given, replaces the workspace walk.
modernize_document :: proc(
	document: ^Document,
	selected: map[string]struct{},
	config: ^common.Config,
	files: []Package_File = {},
) -> (
	result: Modernize_Result,
) {
	original, original_used := document.text, document.used_text
	result.text = string(original[:original_used])
	if document.ast.syntax_error_count > 0 {
		result.syntax_error = true
		return
	}
	defer if raw_data(document.text) != raw_data(original) {
		document.text, document.used_text = original, original_used
		parse_document(document, config)
	}

	applied := make([dynamic]Modernize_Applied, context.temp_allocator)
	verdicts := Param_Verdicts {
		verdicts = make(map[Param_Key]bool, context.temp_allocator),
	}
	for pass := 1;; pass += 1 {
		verdicts.fresh = pass == 1
		fixes := modernize_fixes(document, selected, config, files, &verdicts)
		if len(fixes) == 0 {
			result.converged = true
			break
		}
		if pass > MODERNIZE_MAX_PASSES do break

		kept, text, ok := modernize_pass(document, fixes, config)
		if !ok {
			failed := make([dynamic]string, context.temp_allocator)
			for fix in kept do if !slice.contains(failed[:], fix.rule) do append(&failed, fix.rule)
			result.failed = failed[:]
			break
		}
		if len(kept) == 0 {
			result.stalled = true
			break
		}

		line, line_start, at := 1, 0, 0
		for fix in kept {
			for ; at < fix.start; at += 1 {
				if result.text[at] == '\n' {
					line += 1
					line_start = at + 1
				}
			}
			append(&applied, Modernize_Applied{fix.rule, fix.title, pass, line, fix.start - line_start + 1})
		}
		result.text = text
	}
	result.applied = applied[:]
	return
}

// The insertions of the missing import paths, sorted. A path goes among the imports of its
// collection. The rest share one insertion after the last top-level import, else after the
// package clause.
@(private = "file")
imports_insert :: proc(document: ^Document, fixes: []Modernize_Fix) -> []Modernize_Fix {
	paths := make([dynamic]string, context.temp_allocator)
	for fix in fixes do for path in fix.imports do append(&paths, path)
	if len(paths) == 0 do return nil
	slice.sort(paths[:])

	// rols: one insertion per grouped path. Insertions at one offset keep this sorted order, since
	// modernize_pass sorts the edits stably.
	inserts := make([dynamic]Modernize_Fix, context.temp_allocator)
	ungrouped := make([dynamic]string, context.temp_allocator)
	for path in slice.unique(paths[:]) {
		if offset, ok := import_group_offset(document, path); ok {
			append(&inserts, Modernize_Fix{start = offset, end = offset, text = fmt.tprintf("import \"%s\"\n", path)})
		} else {
			append(&ungrouped, path)
		}
	}
	if len(ungrouped) == 0 do return inserts[:]

	src := document.ast.src
	after, has_import := -1, false
	for decl in document.ast.decls {
		if imp, is_import := decl.derived.(^ast.Import_Decl); is_import {
			after = max(after, imp.end.offset)
			has_import = true
		}
	}
	if !has_import && document.ast.pkg_decl != nil {
		after = document.ast.pkg_decl.end.offset
	}
	offset := len(src)
	if after >= 0 {
		if newline := strings.index_byte(src[after:], '\n'); newline >= 0 {
			offset = after + newline + 1
		}
	}

	b := strings.builder_make(context.temp_allocator)
	if offset == len(src) && !strings.has_suffix(src, "\n") do strings.write_byte(&b, '\n')
	if !has_import do strings.write_byte(&b, '\n')
	for path in ungrouped {
		fmt.sbprintf(&b, "import \"%s\"\n", path)
	}
	append(&inserts, Modernize_Fix{start = offset, end = offset, text = strings.to_string(b)})
	return inserts[:]
}

// edits are sorted by start; one that begins inside the previous one fails the splice.
@(private = "file")
splice :: proc(src: string, edits: []Modernize_Fix) -> (string, bool) {
	b := strings.builder_make(context.temp_allocator)
	at := 0
	for edit in edits {
		if edit.start < at || edit.end > len(src) do return "", false
		strings.write_string(&b, src[at:edit.start])
		strings.write_string(&b, edit.text)
		at = edit.end
	}
	strings.write_string(&b, src[at:])
	return strings.to_string(b), true
}

// The document text points at text, which must outlive the document's use of it.
@(private = "file")
reparse :: proc(document: ^Document, text: string, config: ^common.Config) -> bool {
	document.text = transmute([]u8)text
	document.used_text = len(text)
	parse_document(document, config)
	return document.ast.syntax_error_count == 0
}

// name, the qualifier a fix at offset writes, would not reach the package of import_path: the
// file declares it, imports another package under it, or the enclosing top-level declaration
// declares it as a parameter, result, local or loop variable.
@(private = "package")
name_taken :: proc(document: ^Document, offset: int, name, import_path: string) -> bool {
	fullpath := fmt.tprintf("\"%s\"", import_path)
	for decl in document.ast.decls {
		#partial switch d in decl.derived {
		case ^ast.Import_Decl:
			if d.fullpath != fullpath && pattern_import_name(d) == name do return true
		case ^ast.Value_Decl:
			for n in d.names do if ident_is(n, name) do return true
		}
		if decl.pos.offset <= offset && offset < decl.end.offset && declares_inside(decl, name) do return true
	}
	return false
}

@(private = "package")
ident_is :: proc(expr: ^ast.Expr, name: string) -> bool {
	ident, ok := expr.derived.(^ast.Ident)
	return ok && ident.name == name
}

@(private = "package")
declares_inside :: proc(root: ^ast.Node, name: string) -> bool {
	Search :: struct {
		name:  string,
		found: bool,
	}
	search := Search{name, false}
	visitor := ast.Visitor {
		data = &search,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			search := (^Search)(visitor.data)
			names: []^ast.Expr
			unrolled: [2]^ast.Expr
			#partial switch n in node.derived {
			case ^ast.Value_Decl:
				names = n.names
			case ^ast.Field:
				names = n.names
			case ^ast.Range_Stmt:
				names = n.vals
			case ^ast.Unroll_Range_Stmt:
				unrolled = {n.val0, n.val1}
				names = unrolled[:]
			}
			for n in names {
				if n == nil do continue
				// `for &e in xs` declares e.
				name := n
				if ref, is_ref := n.derived.(^ast.Unary_Expr); is_ref && ref.op.kind == .And do name = ref.expr
				if ident_is(name, search.name) do search.found = true
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
	return search.found
}
