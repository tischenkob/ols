package server

import "core:fmt"
import "core:strings"

import "src:common"

// The import of document whose name a rename at position changes, and range, the token under the cursor.
// The position is on the alias of an import, or on the `x` of a qualifier `x.y` or `alias :: x` that
// resolves to an import of document; a local named like the import does not count.
import_name_at :: proc(
	document: ^Document,
	position: common.Position,
) -> (
	imp: Package,
	range: common.Range,
	ok: bool,
) {
	context.allocator = context.temp_allocator
	src := document.ast.src
	offset := common.get_absolute_position(position, document.text[:document.used_text]) or_return
	for candidate in document.imports {
		name := candidate.import_decl.name
		if name.text != "" && name.pos.offset <= offset && offset <= name.pos.offset + len(name.text) {
			return candidate, text_range(name.pos, name.text, src), true
		}
	}

	start, end := offset, offset
	for start > 0 && is_ident_rune(rune(src[start - 1])) {
		start -= 1
	}
	for end < len(src) && is_ident_rune(rune(src[end])) {
		end += 1
	}
	word := src[start:end]
	for candidate in document.imports {
		if candidate.base != word {
			continue
		}
		for qualifier in qualifier_uses(document, word) {
			if qualifier.ident.pos.offset != start {
				continue
			}
			range = common.get_token_range(qualifier.ident^, src)
			symbol := resolve_name_at(document, range.start, start, word) or_return
			if symbol.type == .Package && canonical_dir(symbol.pkg) == canonical_dir(candidate.name) {
				return candidate, range, true
			}
			return
		}
	}
	return
}

// Renames the import whose name is at position, in document only: its alias, or a new alias before the
// path of an import without one, and every qualifier that resolves to it. found is false when position is
// not on an import name. reasons holds one cause per refusal. Renaming to the current name gives an
// empty edit, a no-op.
rename_import :: proc(
	document: ^Document,
	position: common.Position,
	new_name: string,
) -> (
	edit: WorkspaceEdit,
	warnings: []string,
	reasons: []string,
	found: bool,
) {
	context.allocator = context.temp_allocator
	imp, _ := import_name_at(document, position) or_return
	if imp.base == new_name {
		return {}, {}, {}, true
	}

	out := make([dynamic]string)
	if check_new_name(&out, new_name) && is_builtin_name(new_name, document.fullpath) {
		append(&out, fmt.tprintf("`%s` is a builtin name, which the import would shadow", new_name))
	}
	if len(out) > 0 {
		return {}, {}, out[:], true
	}
	check_import_name(&out, document, imp.import_decl, new_name, "")

	src := document.ast.src
	more := make([dynamic]string)
	edits := make([dynamic]TextEdit)
	for range in import_qualifiers(document, imp.base, new_name, canonical_dir(imp.name), &out, &more) {
		append(&edits, TextEdit{range = range, newText = new_name})
	}
	if len(out) > 0 {
		return {}, {}, out[:], true
	}
	// The import edit goes last, so the first edit holds the old name for the CLI's compile gate.
	decl := imp.import_decl
	if decl.name.text != "" {
		append(&edits, TextEdit{range = text_range(decl.name.pos, decl.name.text, src), newText = new_name})
	} else {
		at := text_range(decl.relpath.pos, "", src)
		append(&edits, TextEdit{range = at, newText = strings.concatenate({new_name, " "})})
	}
	edit.changes = make(map[string][]TextEdit)
	edit.changes[document.uri.uri] = edits[:]
	return edit, more[:], {}, true
}
