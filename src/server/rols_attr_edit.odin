package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

import "src:common"

// Edits the `@(…)` attributes of declarations where the source writes them. A declaration is a value
// declaration, a foreign block, a foreign import or an import, at any depth: in `when` blocks, foreign
// blocks and procedure bodies too. The index merges foreign-block attributes into member declarations;
// these edits read a fresh parse, so they never touch a merged copy.

// Adds spec, `KEY` or `KEY=VALUE`, to the declaration at position: into its last attribute group, or as
// a new `@(spec)` line above it at its indentation. reasons holds one cause per refusal and makes ok false.
attr_add :: proc(
	document: ^Document,
	position: common.Position,
	spec: string,
	config: ^common.Config,
) -> (
	edit: WorkspaceEdit,
	warnings: []string,
	reasons: []string,
	ok: bool,
) {
	context.allocator = context.temp_allocator
	out := make([dynamic]string)

	key, sep, value := strings.partition(spec, "=")
	key, value = strings.trim_space(key), strings.trim_space(value)
	if check_new_name(&out, key) && sep != "" && !is_attr_value(key, value) {
		append(&out, fmt.tprintf("`%s` is not an Odin expression, so it cannot be the value of `%s`", value, key))
	}
	decl, found := attr_target(&out, document, position, config)
	if !found || len(out) > 0 {
		return {}, {}, out[:], false
	}
	src := document.ast.src
	for group in decl.groups {
		for elem in group.elems {
			if ident, _, is_key := unwrap_attr_elem(elem); is_key && ident.name == key {
				append(
					&out,
					fmt.tprintf(
						"%s: the declaration already has the attribute `%s`",
						pos_text(document.fullpath, ident.pos),
						key,
					),
				)
			}
		}
	}
	if len(out) > 0 {
		return {}, {}, out[:], false
	}

	text := key if sep == "" else strings.concatenate({key, "=", value})
	span: Attr_Span
	if len(decl.groups) > 0 {
		group := decl.groups[len(decl.groups) - 1]
		switch {
		case group.open.line == 0:
			// `@key` has no parentheses: rewrite it as a group.
			elem := group.elems[0]
			span = {
				group.pos.offset,
				group.end.offset,
				strings.concatenate({"@(", src[elem.pos.offset:elem.end.offset], ", ", text, ")"}),
			}
		case len(group.elems) == 0:
			span = {group.close.offset, group.close.offset, text}
		case:
			last := group.elems[len(group.elems) - 1].end.offset
			span = {last, last, strings.concatenate({", ", text})}
		}
	} else {
		start := decl.node.pos.offset
		line := line_start(src, start)
		indent := src[line:start]
		if is_blank(indent) {
			newline := "\r\n" if strings.has_suffix(src[:line], "\r\n") else "\n"
			span = {line, line, strings.concatenate({indent, "@(", text, ")", newline})}
		} else {
			// Something precedes the declaration on its line, as in `when X { x :: 0 }`.
			span = {start, start, strings.concatenate({"@(", text, ") "})}
		}
	}
	return file_edit(document.uri.uri, src, {span}), {}, {}, true
}

// Removes every `key` element from the declaration at position, the whole group when it empties, and its
// line when the line holds only that group. A declaration without key gives an empty edit, a no-op.
attr_remove :: proc(
	document: ^Document,
	position: common.Position,
	key: string,
	config: ^common.Config,
) -> (
	edit: WorkspaceEdit,
	warnings: []string,
	reasons: []string,
	ok: bool,
) {
	context.allocator = context.temp_allocator
	out := make([dynamic]string)
	check_new_name(&out, key)
	decl, found := attr_target(&out, document, position, config)
	if !found || len(out) > 0 {
		return {}, {}, out[:], false
	}
	spans := make([dynamic]Attr_Span)
	remove_key(&spans, document.ast.src, decl, key)
	if len(spans) == 0 {
		return {}, {}, {}, true
	}
	return file_edit(document.uri.uri, document.ast.src, spans[:]), {}, {}, true
}

// A declaration that carries attributes, with its groups in source order. head_end is the offset where
// the part a target may point at ends: the values of a value declaration, or the body of a foreign block.
@(private = "file")
Attr_Decl :: struct {
	node:     ^ast.Node,
	groups:   []^ast.Attribute,
	head_end: int,
}

// Replaces src[start:end] with text.
@(private = "file")
Attr_Span :: struct {
	start, end: int,
	text:       string,
}

// Removes key from every declaration in dir, or in the workspace when dir is "", when new_key is ""; else
// renames key to new_key there, keeping its value, and refuses at each declaration that already has new_key.
// files, when given, replaces the workspace walk.
attr_sweep :: proc(
	dir, key, new_key: string,
	config: ^common.Config,
	files: []Package_File = {},
) -> (
	edit: WorkspaceEdit,
	warnings: []string,
	reasons: []string,
	ok: bool,
) {
	context.allocator = context.temp_allocator
	out := make([dynamic]string)
	renaming := new_key != ""
	check_new_name(&out, key)
	if renaming {
		check_new_name(&out, new_key)
	}
	if dir != "" {
		check_attr_dir(&out, dir, config, len(files) > 0)
	}
	if len(out) > 0 {
		return {}, {}, out[:], false
	}
	if key == new_key {
		return {}, {}, {}, true
	}

	all_warnings := make([dynamic]string)
	edits := make(map[string][dynamic]Attr_Span)
	texts := make(map[string]string)
	for file in workspace_odin_files("", files) {
		if dir != "" {
			if _, inside := relative_dir(dir, path.dir(file.fullpath)); !inside do continue
		}
		text := file.text
		if text == "" {
			data, err := os.read_entire_file(file.fullpath, context.temp_allocator)
			if err != nil {
				continue
			}
			text = string(data)
		}
		if !contains_word(text, key) {
			continue
		}
		ast_file, parsed := parse_attr_file(file.fullpath, text)
		if !parsed {
			append(
				&all_warnings,
				fmt.tprintf("cannot parse %s, which mentions `%s`; attr does not change it", file.fullpath, key),
			)
			continue
		}
		spans := make([dynamic]Attr_Span)
		for decl in attr_decls(&ast_file) {
			if !renaming {
				remove_key(&spans, text, decl, key)
				continue
			}
			taken := false
			for group in decl.groups {
				for elem in group.elems {
					ident, _ := unwrap_attr_elem(elem) or_continue
					taken ||= ident.name == new_key
				}
			}
			for group in decl.groups {
				for elem in group.elems {
					ident, _ := unwrap_attr_elem(elem) or_continue
					if ident.name != key {
						continue
					}
					if taken {
						append(
							&out,
							fmt.tprintf(
								"%s: the declaration already has `%s`, so renaming `%s` would duplicate it",
								pos_text(file.fullpath, ident.pos),
								new_key,
								key,
							),
						)
					}
					append(&spans, Attr_Span{ident.pos.offset, ident.end.offset, new_key})
				}
			}
		}
		if len(spans) > 0 {
			uri := common.create_uri(file.fullpath, context.temp_allocator).uri
			edits[uri] = spans
			texts[uri] = text
		}
	}
	if len(out) > 0 {
		return {}, {}, out[:], false
	}

	append(
		&all_warnings,
		..skipped_files_warning(key, config, actor = "attr rename" if renaming else "attr remove", dir = dir),
	)
	if len(edits) == 0 {
		return {}, all_warnings[:], {}, true
	}
	edit.changes = make(map[string][]TextEdit)
	for uri, spans in edits {
		edit.changes[uri] = span_edits(spans[:], texts[uri])
	}
	return edit, all_warnings[:], {}, true
}

// Appends a cause when dir is in core:, vendor: or base:, outside the workspace folders, or, when the
// disk is read and dir is not in a library, not a directory.
@(private = "file")
check_attr_dir :: proc(out: ^[dynamic]string, dir: string, config: ^common.Config, in_memory: bool) {
	if _, library := check_dir_location(out, dir, config); !library && !in_memory && !os.is_directory(dir) {
		append(out, fmt.tprintf("%s is not a directory", dir))
	}
}

// The declaration whose head holds position. Appends a cause when there is none, when position is on a
// struct field, enum member or bit_field field, or when the file is in a library.
@(private = "file")
attr_target :: proc(
	out: ^[dynamic]string,
	document: ^Document,
	position: common.Position,
	config: ^common.Config,
) -> (
	target: Attr_Decl,
	ok: bool,
) {
	if reason, library := library_location(document.uri.uri, config); library {
		append(out, reason)
		return
	}
	offset, offset_ok := common.get_absolute_position(position, document.text[:document.used_text])
	if !offset_ok {
		append(out, "the position is past the end of the file")
		return
	}
	decls := attr_decls(&document.ast)
	// Members first: the head of `x: struct {f: int}` spans its type, members included.
	for decl in decls {
		value_decl := decl.node.derived.(^ast.Value_Decl) or_continue
		types := make([dynamic]^ast.Expr)
		append(&types, value_decl.type)
		append(&types, ..value_decl.values)
		for type_expr in types {
			members := type_members(type_expr) or_continue
			for ident in members {
				if ident.pos.offset <= offset && offset <= ident.end.offset {
					append(
						out,
						fmt.tprintf(
							"`%s` is a member of a struct, enum or bit_field type; attributes go on declarations",
							ident.name,
						),
					)
					return
				}
			}
		}
	}
	// Heads do not nest, but the last match is the innermost one anyway.
	for decl in decls {
		start := decl.groups[0].pos.offset if len(decl.groups) > 0 else decl.node.pos.offset
		if start <= offset && offset <= decl.head_end {
			target, ok = decl, true
		}
	}
	if ok {
		return
	}
	append(
		out,
		"no declaration at the position; attributes go on value, foreign block, foreign import and import declarations",
	)
	return
}

// Every declaration of file that can carry attributes, at any depth, in source order.
@(private = "file")
attr_decls :: proc(file: ^ast.File) -> []Attr_Decl {
	found := make([dynamic]Attr_Decl)
	visitor := ast.Visitor {
		visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			decl := Attr_Decl {
				node     = node,
				head_end = node.end.offset,
			}
			attributes: []^ast.Attribute
			#partial switch n in node.derived {
			case ^ast.Value_Decl:
				attributes = n.attributes[:]
				if len(n.values) > 0 {
					decl.head_end = n.values[0].pos.offset
				}
			case ^ast.Foreign_Block_Decl:
				attributes = n.attributes[:]
				if n.body != nil {
					decl.head_end = n.body.pos.offset
				}
			case ^ast.Foreign_Import_Decl:
				attributes = n.attributes[:]
			case ^ast.Import_Decl:
				attributes = n.attributes[:]
			case:
				return v
			}
			// The parser appends an outer `@(a)` after the inner `@(b)` of `@(a) @(b) x :: 0`.
			decl.groups = slice.clone(attributes)
			slice.sort_by(decl.groups, proc(a, b: ^ast.Attribute) -> bool {
				return a.pos.offset < b.pos.offset
			})
			append((^[dynamic]Attr_Decl)(v.data), decl)
			return v
		},
		data = &found,
	}
	for decl in file.decls {
		ast.walk(&visitor, decl)
	}
	return found[:]
}

// Appends the spans that remove every key element of decl from src; an emptied group goes whole. A run of
// removed elements takes the comma and blanks after it, or its lines and the rest of its last line when it
// starts a line. A run at the end takes its lines when it starts a line, else the comma before it. So the
// comments of kept elements stay, and those after a removed element on its line go with it.
@(private = "file")
remove_key :: proc(spans: ^[dynamic]Attr_Span, src: string, decl: Attr_Decl, key: string) {
	for group in decl.groups {
		elems := group.elems
		removed := make([]bool, len(elems))
		count := 0
		for elem, i in elems {
			if ident, _, is_key := unwrap_attr_elem(elem); is_key && ident.name == key {
				removed[i] = true
				count += 1
			}
		}
		if count == 0 {
			continue
		}
		if count == len(elems) {
			append(spans, group_span(src, group))
			continue
		}
		for i := 0; i < len(elems); i += 1 {
			if !removed[i] {
				continue
			}
			j := i
			for j + 1 < len(elems) && removed[j + 1] {
				j += 1
			}
			first := elems[i].pos.offset
			close := group.close.offset
			switch {
			case j + 1 < len(elems):
				// The comma after the run ends it, so a comment before the next element stays.
				next := elems[j + 1].pos.offset
				comma := comma_after(src, elems[j].end.offset, next)
				// A newline counts when only blanks or a line comment precede it: a block comment may span it.
				newline := strings.index_byte(src[comma:next], '\n')
				if newline > 0 {
					rest := strings.trim_left(src[comma + 1:comma + newline], " \t\r")
					if rest == "" || strings.has_prefix(rest, "//") {
						line_end := comma + newline
						if is_blank(src[line_start(src, first):first]) {
							append(spans, Attr_Span{line_start(src, first), line_end + 1, ""})
							break
						}
						// The run follows code on its line: it goes from the comma before it to the line end.
						start := first if i == 0 else comma_after(src, elems[i - 1].end.offset, first) + 1
						if src[line_end - 1] == '\r' {
							line_end -= 1
						}
						append(spans, Attr_Span{start, line_end, ""})
						break
					}
				}
				end := comma + 1 if src[comma] == ',' else comma
				for end < next && (src[end] == ' ' || src[end] == '\t') {
					end += 1
				}
				append(spans, Attr_Span{first, end, ""})
			case is_blank(src[line_start(src, first):first]):
				// One element per line: the run's lines go, up to the line of `)`, or up to `)` on the run's
				// last line, which keeps the run's indentation before it.
				if is_blank(src[line_start(src, close):close]) {
					append(spans, Attr_Span{line_start(src, first), line_start(src, close), ""})
				} else {
					append(spans, Attr_Span{first, close, ""})
				}
			case:
				// A run at the end follows a kept element, since not every element goes.
				append(spans, Attr_Span{comma_after(src, elems[i - 1].end.offset, first), close, ""})
			}
			i = j
		}
	}
}

// The span that deletes group: its whole line when the line holds nothing else, else the group with the
// blanks after it, or before it when it ends the line.
@(private = "file")
group_span :: proc(src: string, group: ^ast.Attribute) -> Attr_Span {
	start, end := group.pos.offset, group.end.offset
	line := line_start(src, start)
	line_end := strings.index_byte(src[end:], '\n')
	line_end = len(src) if line_end < 0 else end + line_end
	before_blank, after_blank := is_blank(src[line:start]), is_blank(src[end:line_end])
	switch {
	case before_blank && after_blank:
		return {line, min(line_end + 1, len(src)), ""}
	case after_blank:
		for start > line && (src[start - 1] == ' ' || src[start - 1] == '\t') {
			start -= 1
		}
	case:
		for end < line_end && (src[end] == ' ' || src[end] == '\t') {
			end += 1
		}
	}
	return {start, end, ""}
}

// One edit per span, with overlapping deletions merged: groups that share a line may both reach a blank.
@(private = "file")
span_edits :: proc(spans: []Attr_Span, src: string) -> []TextEdit {
	slice.sort_by(spans, proc(a, b: Attr_Span) -> bool {
		return a.start < b.start
	})
	merged := make([dynamic]Attr_Span)
	for span in spans {
		if n := len(merged); n > 0 && span.text == "" && merged[n - 1].text == "" && span.start <= merged[n - 1].end {
			merged[n - 1].end = max(merged[n - 1].end, span.end)
			continue
		}
		append(&merged, span)
	}
	text := transmute([]u8)src
	edits := make([]TextEdit, len(merged))
	for span, i in merged {
		edits[i] = {
			range = {
				start = common.get_relative_token_position(span.start, text, 0),
				end = common.get_relative_token_position(span.end, text, 0),
			},
			newText = span.text,
		}
	}
	return edits
}

@(private = "file")
file_edit :: proc(uri, src: string, spans: []Attr_Span) -> (edit: WorkspaceEdit) {
	edit.changes = make(map[string][]TextEdit)
	edit.changes[uri] = span_edits(spans, src)
	return
}

// Whether value parses as one Odin expression that is the whole value of `@(key=value)`.
@(private = "file")
is_attr_value :: proc(key, value: string) -> bool {
	prefix := fmt.tprintf("package attr_value\n@(%s=", key)
	file := parse_attr_file("attr_value.odin", strings.concatenate({prefix, value, ") _x :: 0\n"})) or_return
	if len(file.decls) != 1 {
		return false
	}
	decl := file.decls[0].derived.(^ast.Value_Decl) or_return
	if len(decl.attributes) != 1 || len(decl.attributes[0].elems) != 1 {
		return false
	}
	field := decl.attributes[0].elems[0].derived.(^ast.Field_Value) or_return
	return field.value.pos.offset == len(prefix) && field.value.end.offset == len(prefix) + len(value)
}

// Parses src without reporting its errors; fails on any syntax error.
@(private = "file")
parse_attr_file :: proc(fullpath, src: string) -> (file: ast.File, ok: bool) {
	silent :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
	p := parser.Parser {
		flags = {.Optional_Semicolons},
		err   = silent,
		warn  = silent,
	}
	pkg := new(ast.Package)
	pkg.kind = .Normal
	pkg.fullpath = fullpath
	file = ast.File {
		fullpath = fullpath,
		src      = src,
		pkg      = pkg,
	}
	return file, parse_file(&p, &file) && file.syntax_error_count == 0
}

// The offset of the comma between from and to, skipping comments; from when there is none.
@(private = "file")
comma_after :: proc(src: string, from, to: int) -> int {
	t: tokenizer.Tokenizer
	tokenizer.init(&t, src[from:to], "", proc(pos: tokenizer.Pos, msg: string, args: ..any) {})
	for token := tokenizer.scan(&t); token.kind != .EOF; token = tokenizer.scan(&t) {
		if token.kind == .Comma {
			return from + token.pos.offset
		}
	}
	return from
}

@(private = "file")
line_start :: proc(src: string, offset: int) -> int {
	return strings.last_index_byte(src[:offset], '\n') + 1
}

// Whether s holds only spaces, tabs and carriage returns.
@(private = "file")
is_blank :: proc(s: string) -> bool {
	return strings.trim_left(s, " \t\r") == ""
}

@(private = "file")
pos_text :: proc(fullpath: string, pos: tokenizer.Pos) -> string {
	return fmt.tprintf("%s:%d:%d", fullpath, pos.line, pos.column)
}
