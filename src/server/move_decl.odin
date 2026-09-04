package server

import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

import "src:common"

// A top-level declaration ready to leave its file: the lines to delete from the source, the
// lines to write elsewhere, and the imports those lines use.
Move :: struct {
	document:           ^Document,
	decl:               ^ast.Value_Decl,
	del_start, del_end: int,
	text:               string,
	imports:            []Package,
}

move_declaration :: proc(
	document: ^Document,
	position: common.Position,
	target_uri: string,
	files: []Package_File = {},
) -> (
	edit: WorkspaceEdit,
	ok: bool,
) {
	offset := common.get_absolute_position(position, document.text[:document.used_text]) or_return
	move := prepare_move(document, offset) or_return
	return move_edit(move, target_uri, files)
}

// The declaration directly at file scope whose name spans offset; those under `when` or in
// foreign blocks are not returned.
top_decl_at :: proc(document: ^Document, offset: int) -> (^ast.Value_Decl, bool) {
	for stmt in document.ast.decls {
		decl := stmt.derived.(^ast.Value_Decl) or_continue
		if len(decl.names) == 1 && decl.names[0].pos.offset <= offset && offset <= decl.names[0].end.offset {
			_, is_ident := decl.names[0].derived.(^ast.Ident)
			return decl, is_ident
		}
	}
	return nil, false
}

// Refused when file-scoped privacy is involved, since a file-private declaration, or one using a
// file-private symbol, would change meaning in another file.
prepare_move :: proc(document: ^Document, offset: int) -> (move: Move, ok: bool) {
	if parser.parse_file_tags(document.ast, context.temp_allocator).private == .File {
		return {}, false
	}
	decl := top_decl_at(document, offset) or_return
	if is_file_private(decl.attributes[:]) {
		return {}, false
	}

	privates := make(map[common.Range]struct{}, context.temp_allocator)
	src := string(document.text[:document.used_text])
	for other in top_level_value_decls(document.ast) {
		if is_file_private(other.attributes[:]) {
			for name in other.names {
				privates[common.get_token_range(name, src)] = {}
			}
		}
	}
	if len(privates) > 0 {
		for _, hit in resolve_entire_file_for_references(document, context.temp_allocator, .Identifier, "") {
			if hit.node.pos.offset < decl.pos.offset || decl.end.offset <= hit.node.pos.offset {
				continue
			}
			if hit.symbol.uri == document.uri.uri && hit.symbol.range in privates {
				return {}, false
			}
		}
	}

	start, end := decl.pos.offset, decl.end.offset
	for attribute in decl.attributes {
		start = min(start, attribute.pos.offset)
	}
	if decl.docs != nil {
		start = min(start, decl.docs.pos.offset)
	}
	if decl.comment != nil {
		end = max(end, decl.comment.end.offset)
	}
	start = strings.last_index_byte(src[:start], '\n') + 1
	if nl := strings.index_byte(src[end:], '\n'); nl >= 0 {
		end += nl + 1
	} else {
		end = len(src)
	}

	move = Move{document = document, decl = decl, del_start = start, del_end = end}
	move.text = src[start:end]
	if !strings.has_suffix(move.text, "\n") {
		move.text = strings.concatenate({move.text, "\n"}, context.temp_allocator)
	}
	// Take one adjoining blank line along so the source keeps single blank lines between declarations.
	if end < len(src) && src[end] == '\n' {
		move.del_end += 1
	} else if start >= 2 && src[start - 1] == '\n' && src[start - 2] == '\n' {
		move.del_start -= 1
	}

	move.imports = used_imports(document, decl)
	return move, true
}

// Builds the edit moving move into target_uri, a file of the same directory. An existing target
// gets the text appended and the missing imports inserted after its package line; a missing one
// is created.
move_edit :: proc(move: Move, target_uri: string, files: []Package_File) -> (WorkspaceEdit, bool) {
	document := move.document
	target_path := common.uri_to_path(target_uri, context.temp_allocator)
	if target_uri == document.uri.uri || path.ext(target_path) != ".odin" {
		return {}, false
	}
	if path.dir(target_path, context.temp_allocator) != path.dir(document.fullpath, context.temp_allocator) {
		return {}, false
	}

	changes := make(Changes, context.temp_allocator)
	append_edit(&changes, document, move.del_start, move.del_end, "")

	if !package_file_exists(target_path, files) {
		content := strings.builder_make(context.temp_allocator)
		strings.write_string(&content, "package ")
		strings.write_string(&content, document.ast.pkg_name)
		strings.write_string(&content, "\n")
		if len(move.imports) > 0 {
			strings.write_string(&content, "\n")
			for imp in move.imports {
				strings.write_string(&content, node_text(document.ast.src, imp.import_decl))
				strings.write_string(&content, "\n")
			}
		}
		strings.write_string(&content, "\n")
		strings.write_string(&content, move.text)

		document_changes := make([]DocumentChange, 3, context.temp_allocator)
		document_changes[0] = CreateFile{kind = "create", uri = target_uri, options = {ignoreIfExists = true}}
		document_changes[1] = TextDocumentEdit{textDocument = {uri = document.uri.uri}, edits = changes[document.uri.uri][:]}
		insert := make([]TextEdit, 1, context.temp_allocator)
		insert[0] = {newText = strings.to_string(content)}
		document_changes[2] = TextDocumentEdit{textDocument = {uri = target_uri}, edits = insert}
		return WorkspaceEdit{documentChanges = document_changes}, true
	}

	h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}
	target := hierarchy_document(&h, target_uri)
	if target == nil || target.ast.pkg_name != document.ast.pkg_name {
		return {}, false
	}
	text := string(target.text[:target.used_text])

	missing := make([dynamic]string, context.temp_allocator)
	for imp in move.imports {
		already := false
		for existing in target.imports {
			already |= existing.name == imp.name
		}
		if !already {
			append(&missing, node_text(document.ast.src, imp.import_decl))
		}
	}
	if len(missing) > 0 {
		at := target.ast.pkg_decl.end.offset
		if nl := strings.index_byte(text[at:], '\n'); nl >= 0 {
			at += nl
		} else {
			at = len(text)
		}
		append_edit(
			&changes,
			target,
			at,
			at,
			strings.concatenate({"\n\n", strings.join(missing[:], "\n", context.temp_allocator)}, context.temp_allocator),
		)
	}
	separator := "\n" if strings.has_suffix(text, "\n") else "\n\n"
	append_edit(&changes, target, len(text), len(text), strings.concatenate({separator, move.text}, context.temp_allocator))
	return workspace_edit(changes), true
}

is_file_private :: proc(attributes: []^ast.Attribute) -> bool {
	for attribute in attributes {
		for elem in attribute.elems {
			ident, value, ok := unwrap_attr_elem(elem)
			if !ok || ident.name != "private" || value == nil {
				continue
			}
			if lit, is_lit := value.derived.(^ast.Basic_Lit); is_lit && lit.tok.text == "\"file\"" {
				return true
			}
		}
	}
	return false
}

// The imports of document that decl names as the package of a selector.
used_imports :: proc(document: ^Document, decl: ^ast.Value_Decl) -> []Package {
	names := make(map[string]struct{}, context.temp_allocator)
	visitor := ast.Visitor {
		data = &names,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			if selector, ok := node.derived.(^ast.Selector_Expr); ok {
				if ident, is_ident := selector.expr.derived.(^ast.Ident); is_ident {
					(^map[string]struct{})(visitor.data)[ident.name] = {}
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, decl)

	used := make([dynamic]Package, context.temp_allocator)
	for imp in document.imports {
		if imp.base in names {
			append(&used, imp)
		}
	}
	return used[:]
}

package_file_exists :: proc(fullpath: string, files: []Package_File) -> bool {
	for file in files {
		if file.fullpath == fullpath {
			return true
		}
	}
	return len(files) == 0 && os.exists(fullpath)
}

// The other .odin files of the document's directory, sorted by name. files stands in for the
// directory when given.
package_siblings :: proc(document: ^Document, files: []Package_File) -> []string {
	dir := document.package_name
	paths := make([dynamic]string, context.temp_allocator)
	if len(files) > 0 {
		for file in files {
			if path.dir(file.fullpath, context.temp_allocator) == dir {
				append(&paths, file.fullpath)
			}
		}
	} else if matches, err := filepath.glob(path.join({dir, "*.odin"}, context.temp_allocator), context.temp_allocator); err == nil {
		append(&paths, ..matches)
	}
	siblings := make([dynamic]string, context.temp_allocator)
	for p in paths {
		if p != document.fullpath {
			append(&siblings, p)
		}
	}
	slice.sort(siblings[:])
	return siblings[:]
}
