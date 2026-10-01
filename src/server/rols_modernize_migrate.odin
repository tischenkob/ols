#+private file

package server

import "core:odin/ast"
import "core:slice"
import "core:strings"

// Rewrites from deprecated or removed Odin forms to the forms of the current compiler. Every
// default rule turns code the compiler warns about or rejects into the current spelling with the
// same meaning. They run only from `ols query modernize` and have no editor diagnostic.
@(private = "package")
migration_rules := [?]Modernize_Rule {
	{"base-imports", "migration", true},
	{"os2-import", "migration", true},
	{"field-align", "migration", true},
	{"align-parens", "migration", true},
	{"for-blank", "migration", true},
	{"switch-blank", "migration", true},
	{"partial-dup", "migration", true},
	{"optimization-mode", "migration", true},
	{"proc-do-body", "migration", true},
	{"strconv-itoa", "migration", true},
	{"strconv-ftoa", "migration", true},
	{"feature-tags", "migration", true},
	// The compiler ignores `//+build` and `//+private` comments, so the file is built everywhere and
	// its declarations are public. The `#+` tag brings the filter back, which changes the build.
	{"file-tags", "review", false},
}

// Packages that moved from core: to base:.
BASE_PACKAGES :: []string{"runtime", "intrinsics", "builtin"}

// Tags the old `//+` comment form had and the `#+` form still has.
FILE_TAGS :: []string{"build", "private", "ignore", "lazy", "no-instrumentation", "vet"}

// The compiler messages name the current mode with the same behaviour as each removed one.
OPTIMIZATION_MODES :: [][2]string{{"minimal", "none"}, {"size", "favor_size"}, {"speed", "favor_size"}}

Migrator :: struct {
	document:                   ^Document,
	src:                        string,
	selected:                   map[string]struct{},
	out:                        [dynamic]Modernize_Fix,
	strconv_calls:              [dynamic]^ast.Call_Expr,
	needs_using, needs_dynamic: bool,
}

@(private = "package")
migration_fixes :: proc(document: ^Document, selected: map[string]struct{}) -> []Modernize_Fix {
	m := Migrator {
		document      = document,
		src           = document.ast.src,
		selected      = selected,
		out           = make([dynamic]Modernize_Fix, context.temp_allocator),
		strconv_calls = make([dynamic]^ast.Call_Expr, context.temp_allocator),
	}
	visitor := ast.Visitor {
		data = &m,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			visit((^Migrator)(visitor.data), node)
			return visitor
		},
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	strconv_fixes(&m)
	feature_tags(&m)
	file_tags(&m)
	return m.out[:]
}

add :: proc(m: ^Migrator, rule, title: string, start, end: int, text: string) {
	if rule not_in m.selected do return
	append(&m.out, Modernize_Fix{rule = rule, title = title, start = start, end = end, text = text})
}

visit :: proc(m: ^Migrator, node: ^ast.Node) {
	src := m.src
	#partial switch n in node.derived {
	case ^ast.Import_Decl:
		import_path(m, n)
	case ^ast.Struct_Type:
		if n.min_field_align != nil {
			if start, end := before_on_line(src, n.min_field_align.pos.offset);
			   strings.has_suffix(src[start:end], "#field_align") {
				add(
					m,
					"field-align",
					"Rename #field_align to #min_field_align",
					end - len("field_align"),
					end,
					"min_field_align",
				)
			}
		}
		for expr in ([]^ast.Expr{n.align, n.min_field_align, n.max_field_align}) do align_parens(m, expr)
	case ^ast.Union_Type:
		align_parens(m, n.align)
	case ^ast.Range_Stmt:
		if len(n.vals) == 0 {
			add(m, "for-blank", "Write `for _ in`", n.in_pos.offset, n.in_pos.offset, "_ ")
		}
	case ^ast.Type_Switch_Stmt:
		// `switch in u` parses with a blank on the left that sits at the switch keyword.
		if tag, ok := n.tag.derived.(^ast.Assign_Stmt);
		   ok && len(tag.lhs) == 1 && tag.lhs[0].pos.offset == n.switch_pos.offset {
			add(m, "switch-blank", "Write `switch _ in`", tag.op.pos.offset, tag.op.pos.offset, "_ ")
		}
		if n.partial do partial_dup(m, n.switch_pos.offset)
	case ^ast.Switch_Stmt:
		if n.partial do partial_dup(m, n.switch_pos.offset)
	case ^ast.Attribute:
		for elem in n.elems {
			fv, is_fv := elem.derived.(^ast.Field_Value)
			if !is_fv || !ident_is(fv.field, "optimization_mode") do continue
			lit, is_lit := fv.value.derived.(^ast.Basic_Lit)
			if !is_lit || lit.tok.kind != .String do continue
			for mode in OPTIMIZATION_MODES {
				if strings.trim(lit.tok.text, "\"`") != mode[0] do continue
				text := strings.concatenate({"\"", mode[1], "\""}, context.temp_allocator)
				add(
					m,
					"optimization-mode",
					"Use the current optimization_mode name",
					lit.pos.offset,
					lit.end.offset,
					text,
				)
			}
		}
	case ^ast.Proc_Lit:
		proc_do_body(m, n)
	case ^ast.Proc_Type:
		if n.params == nil do break
		for field in n.params.list do if .Using in field.flags do m.needs_using = true
	case ^ast.Using_Stmt:
		m.needs_using = true
	case ^ast.Comp_Lit:
		// Only a literal whose type is written out; a miss is safe, the compiler error stays.
		if n.type == nil || len(n.elems) == 0 do break
		#partial switch _ in n.type.derived {
		case ^ast.Map_Type, ^ast.Dynamic_Array_Type:
			m.needs_dynamic = true
		}
	case ^ast.Call_Expr:
		if sel, is_sel := n.expr.derived.(^ast.Selector_Expr); is_sel && sel.field != nil {
			if sel.field.name == "itoa" || sel.field.name == "ftoa" do append(&m.strconv_calls, n)
		}
	}
}

// The text before offset on its line, with trailing spaces trimmed: start is the line start and
// end the offset after the last non-space byte. Scans for a directive stay in this range, so they
// never reach a line comment on an earlier line.
before_on_line :: proc(src: string, offset: int) -> (start, end: int) {
	start = strings.last_index_byte(src[:offset], '\n') + 1
	end = start + len(strings.trim_right_space(src[start:offset]))
	return
}

// `core:runtime`, `core:intrinsics` and `core:builtin` become `base:`; `core:os/os2` becomes
// `core:os` under the name os2, so the code that names it still compiles. A file that already
// imports the target is left alone, since a second import of one package is an error.
import_path :: proc(m: ^Migrator, imp: ^ast.Import_Decl) {
	text := imp.relpath.text
	if len(text) < 2 do return
	quote := text[:1]
	path := text[1:len(text) - 1]
	start, end := imp.relpath.pos.offset, imp.relpath.pos.offset + len(text)
	if strings.has_prefix(path, "core:") && slice.contains(BASE_PACKAGES, path[len("core:"):]) {
		target := strings.concatenate({"base:", path[len("core:"):]}, context.temp_allocator)
		if _, imported := import_alias(m.document, target); imported do return
		add(
			m,
			"base-imports",
			"Import from base:",
			start,
			end,
			strings.concatenate({quote, target, quote}, context.temp_allocator),
		)
	}
	if path == "core:os/os2" {
		if _, imported := import_alias(m.document, "core:os"); imported do return
		name := imp.name.text == "" ? "os2 " : ""
		add(
			m,
			"os2-import",
			"Import core:os",
			start,
			end,
			strings.concatenate({name, quote, "core:os", quote}, context.temp_allocator),
		)
	}
}

align_parens :: proc(m: ^Migrator, expr: ^ast.Expr) {
	if expr == nil do return
	if _, is_paren := expr.derived.(^ast.Paren_Expr); is_paren do return
	_, start := before_on_line(m.src, expr.pos.offset)
	text := strings.concatenate({"(", node_text(m.src, expr), ")"}, context.temp_allocator)
	add(m, "align-parens", "Add parentheses to the directive", start, expr.end.offset, text)
}

// `#partial #partial switch` keeps the #partial next to the switch. The scan stays on the switch's
// line, so a `#partial` that ends a comment on the line above is not taken for a directive.
partial_dup :: proc(m: ^Migrator, switch_offset: int) {
	nearest, earliest := -1, -1
	line, at := before_on_line(m.src, switch_offset)
	for strings.has_suffix(m.src[line:at], "#partial") {
		at -= len("#partial")
		if nearest < 0 do nearest = at
		earliest = at
		_, at = before_on_line(m.src, at)
	}
	if earliest < nearest {
		add(m, "partial-dup", "Remove the repeated #partial", earliest, nearest, "")
	}
}

// `proc() do stmt` gets braces, laid out as the do_block action lays out a block.
proc_do_body :: proc(m: ^Migrator, lit: ^ast.Proc_Lit) {
	if lit.body == nil do return
	block, is_block := lit.body.derived.(^ast.Block_Stmt)
	if !is_block || !block.uses_do do return
	line, at := before_on_line(m.src, block.pos.offset)
	if !strings.has_suffix(m.src[line:at], "do") do return
	ind := get_line_indentation(m.src, lit.pos.offset)
	sb := strings.builder_make(context.temp_allocator)
	write_braces(&sb, m.src, block, ind, indent_unit(m.src, ind, nil))
	add(m, "proc-do-body", "Convert to block", at - len("do"), block.end.offset, strings.to_string(sb))
}

// The deprecated strconv procs are thin wrappers: `itoa(buf, i)` returns `write_int(buf, i64(i),
// 10)` and `ftoa` has the signature and body of `write_float`. The callee must resolve to a
// deprecated proc of a strconv package, so an alias works and a look-alike does not.
strconv_fixes :: proc(m: ^Migrator) {
	if len(m.strconv_calls) == 0 do return
	if "strconv-itoa" not_in m.selected && "strconv-ftoa" not_in m.selected do return
	symbols := resolve_entire_file(m.document)
	for call in m.strconv_calls {
		resolved, found := symbols[uintptr(call.expr)]
		if !found || resolved.is_unresolved || resolved.symbol == nil do continue
		symbol := resolved.symbol
		if !strings.has_suffix(symbol.pkg, "/strconv") || .Deprecated not_in symbol.flags do continue
		sel := call.expr.derived.(^ast.Selector_Expr)
		switch symbol.name {
		case "ftoa":
			add(
				m,
				"strconv-ftoa",
				"Replace with strconv.write_float",
				sel.field.pos.offset,
				sel.field.end.offset,
				"write_float",
			)
		case "itoa":
			if len(call.args) != 2 do continue
			if _, named := call.args[0].derived.(^ast.Field_Value); named do continue
			if _, named := call.args[1].derived.(^ast.Field_Value); named do continue
			text := strings.concatenate(
				{
					node_text(m.src, sel.expr),
					".write_int(",
					node_text(m.src, call.args[0]),
					", i64(",
					node_text(m.src, call.args[1]),
					"), 10)",
				},
				context.temp_allocator,
			)
			add(m, "strconv-itoa", "Replace with strconv.write_int", call.pos.offset, call.end.offset, text)
		}
	}
}

// Adds the `#+feature` tags the compiler wants for using statements and parameters and for
// typed dynamic literals with elements, after the file's last tag, else before the package docs.
feature_tags :: proc(m: ^Migrator) {
	if !m.needs_using && !m.needs_dynamic do return
	for tag in m.document.ast.tags {
		if !strings.has_prefix(tag.text, "#+feature") do continue
		for name in strings.fields(tag.text[len("#+feature"):], context.temp_allocator) {
			name := strings.trim(name, ",")
			if name == "using-stmt" do m.needs_using = false
			if name == "dynamic-literals" do m.needs_dynamic = false
		}
	}
	if !m.needs_using && !m.needs_dynamic do return

	file := m.document.ast
	offset := 0
	if len(file.tags) > 0 {
		last := file.tags[len(file.tags) - 1]
		offset = last.pos.offset + len(last.text)
		if newline := strings.index_byte(m.src[offset:], '\n'); newline >= 0 {
			offset += newline + 1
		} else {
			offset = len(m.src)
		}
	} else if file.pkg_decl != nil {
		offset = file.pkg_decl.pos.offset
		if file.pkg_decl.docs != nil do offset = file.pkg_decl.docs.pos.offset
		offset, _ = before_on_line(m.src, offset)
		// A block comment that ends on the package line starts on an earlier one.
		for group in file.comments {
			if group.pos.offset < offset && offset < group.end.offset {
				offset, _ = before_on_line(m.src, group.pos.offset)
			}
		}
	}

	b := strings.builder_make(context.temp_allocator)
	if offset == len(m.src) && !strings.has_suffix(m.src, "\n") do strings.write_byte(&b, '\n')
	if m.needs_using do strings.write_string(&b, "#+feature using-stmt\n")
	if m.needs_dynamic do strings.write_string(&b, "#+feature dynamic-literals\n")
	add(m, "feature-tags", "Add the #+feature tags the file needs", offset, offset, strings.to_string(b))
}

// `//+build x` and the other old tag comments before the package clause become `#+` tags.
file_tags :: proc(m: ^Migrator) {
	if "file-tags" not_in m.selected || m.document.ast.pkg_decl == nil do return
	package_offset := m.document.ast.pkg_decl.pos.offset
	for group in m.document.ast.comments {
		for comment in group.list {
			if comment.pos.offset >= package_offset do return
			if !strings.has_prefix(comment.text, "//+") do continue
			rest := comment.text[len("//+"):]
			name := rest
			if end := strings.index_any(rest, " \t"); end >= 0 do name = rest[:end]
			if !slice.contains(FILE_TAGS, name) do continue
			add(m, "file-tags", "Write the tag as #+", comment.pos.offset, comment.pos.offset + len("//+"), "#+")
		}
	}
}
