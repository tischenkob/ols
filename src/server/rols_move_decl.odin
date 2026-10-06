package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

import "src:common"

// A top-level declaration ready to leave its file: the lines to delete from the source, the
// lines to write elsewhere, the imports those lines use, and the imports only those lines use.
Move :: struct {
	document:           ^Document,
	decl:               ^ast.Value_Decl,
	del_start, del_end: int,
	text:               string,
	imports:            []Package,
	stale_imports:      []Package,
}

// reason says why a move is refused.
move_declaration :: proc(
	document: ^Document,
	position: common.Position,
	target_uri: string,
	files: []Package_File = {},
) -> (
	edit: WorkspaceEdit,
	reason: string,
	ok: bool,
) {
	offset, offset_ok := common.get_absolute_position(position, document.text[:document.used_text])
	if !offset_ok {
		return {}, "the position is outside the file", false
	}
	move, move_reason, move_ok := prepare_move(document, offset)
	if !move_ok {
		return {}, move_reason, false
	}
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
// file-private symbol, would change meaning in another file. reason says why.
prepare_move :: proc(document: ^Document, offset: int) -> (move: Move, reason: string, ok: bool) {
	if parser.parse_file_tags(document.ast, context.temp_allocator).private == .File {
		return {}, "the file is file-private", false
	}
	decl, found := top_decl_at(document, offset)
	if !found {
		return {}, "the position is not on the name of a top-level declaration", false
	}
	if is_file_private(decl.attributes[:]) {
		return {}, "the declaration is file-private", false
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
				return {}, fmt.tprintf("the declaration uses the file-private symbol %s", node_text(src, hit.node)), false
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

	move = Move {
		document  = document,
		decl      = decl,
		del_start = start,
		del_end   = end,
	}
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
	move.stale_imports = stale_imports(document, decl, move.imports)
	return move, "", true
}

// Builds the edit moving move into target_uri, a file of the same directory. reason says why a move is
// refused.
move_edit :: proc(move: Move, target_uri: string, files: []Package_File) -> (WorkspaceEdit, string, bool) {
	document := move.document
	target_path := common.uri_to_path(target_uri, context.temp_allocator)
	// Both directories resolve symlinks, so a target spelled through /tmp on macOS still compares equal.
	target_dir := canonical_dir(path.dir(target_path, context.temp_allocator))
	document_dir := canonical_dir(path.dir(document.fullpath, context.temp_allocator))
	if target_dir == document_dir && path.base(target_path) == path.base(document.fullpath) {
		return {}, "the target is the file that holds the declaration", false
	}
	if path.ext(target_path) != ".odin" {
		return {}, "the target must be a .odin file", false
	}
	if target_dir != document_dir {
		return {}, "the target must be in the directory of the declaration", false
	}

	// rols: a declaration keeps its meaning and visibility only in a file that builds on the same platforms and
	// has the same `#+private` tag. A new file gets the tags of the source, but its name must carry the same
	// OS and architecture suffix.
	if !package_file_exists(target_path, files) {
		if name_targets_differ(path.base(document.fullpath), path.base(target_path)) {
			return {}, fmt.tprintf("%s has different build constraints", path.base(target_path)), false
		}
	} else {
		h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}
		if target := hierarchy_document(&h, target_uri); target != nil {
			if build_constraints_differ(document, target) {
				return {}, fmt.tprintf("%s has different build constraints", path.base(target_path)), false
			}
			source_private := parser.parse_file_tags(document.ast, context.temp_allocator).private
			target_private := parser.parse_file_tags(target.ast, context.temp_allocator).private
			if source_private != target_private {
				return {},
					fmt.tprintf(
						"%s is %s but the file of the declaration is %s",
						path.base(target_path),
						PRIVACY_NAMES[target_private],
						PRIVACY_NAMES[source_private],
					),
					false
			}
		}
	}

	changes := make(Changes, context.temp_allocator)
	for cut in source_cuts(move) {
		append_edit(&changes, document, cut[0], cut[1], "")
	}
	imports := make([]string, len(move.imports), context.temp_allocator)
	for imp, i in move.imports {
		imports[i] = node_text(document.ast.src, imp.import_decl)
	}
	edit, ok := append_to_package_file(
		&changes,
		document.ast.pkg_name,
		target_uri,
		document.ast.tags[:],
		imports,
		move.text,
		files,
	)
	if !ok {
		return {}, fmt.tprintf("%s cannot be read or belongs to another package", target_path), false
	}
	return edit, "", true
}

@(private = "file", rodata)
PRIVACY_NAMES := [parser.Private_Flag]string {
	.Public  = "public",
	.Package = "#+private",
	.File    = "#+private file",
}

// Whether two files differ in `#+build` lines, `#+build ignore` or the OS and architecture suffix of their names.
@(private = "file")
build_constraints_differ :: proc(a, b: ^Document) -> bool {
	tags_a := parser.parse_file_tags(a.ast, context.temp_allocator)
	tags_b := parser.parse_file_tags(b.ast, context.temp_allocator)
	if tags_a.ignore != tags_b.ignore || !slice.equal(tags_a.build, tags_b.build) {
		return true
	}
	if len(tags_a.build_project_name) != len(tags_b.build_project_name) {
		return true
	}
	for group, i in tags_a.build_project_name {
		if !slice.equal(group, tags_b.build_project_name[i]) do return true
	}
	return name_targets_differ(filepath.base(a.fullpath), filepath.base(b.fullpath))
}

// Whether two file names differ in the OS and architecture suffix that file_name_target reads, or in being hidden.
@(private = "file")
name_targets_differ :: proc(a, b: string) -> bool {
	target_a, hidden_a := file_name_target(a)
	target_b, hidden_b := file_name_target(b)
	return hidden_a != hidden_b || target_a.os != target_b.os || target_a.arch != target_b.arch
}

// The OS and architecture suffix of filename that file_name_target reads, such as `_windows` or
// `_linux_amd64`, or "" for none.
target_suffix :: proc(filename: string) -> string {
	target, _ := file_name_target(filename)
	if target.os == .Unknown && target.arch == .Unknown {
		return ""
	}
	stem := filename
	if dot := strings.last_index_byte(stem, '.'); dot >= 0 do stem = stem[:dot]
	last := strings.last_index_byte(stem, '_')
	if target.os != .Unknown && target.arch != .Unknown {
		// Two segments: a name such as `linux_amd64.odin` is all suffix.
		last = strings.last_index_byte(stem[:last], '_')
		if last < 0 do return strings.concatenate({"_", stem}, context.temp_allocator)
	}
	return stem[last:]
}

// Appends text to target_uri, a file of package pkg_name, inserting after its package line the
// import lines it lacks. A missing target is created with the file tags, such as `#+build linux`, the
// package line and the imports. changes carries the edits of other files that belong to the same workspace edit.
append_to_package_file :: proc(
	changes: ^Changes,
	pkg_name, target_uri: string,
	tags: []tokenizer.Token,
	imports: []string,
	text: string,
	files: []Package_File,
) -> (
	WorkspaceEdit,
	bool,
) {
	target_path := common.uri_to_path(target_uri, context.temp_allocator)
	if !package_file_exists(target_path, files) {
		content := strings.builder_make(context.temp_allocator)
		// A tag token holds its whole line up to a trailing comment.
		for tag in tags {
			strings.write_string(&content, strings.trim_right_space(tag.text))
			strings.write_string(&content, "\n")
		}
		strings.write_string(&content, "package ")
		strings.write_string(&content, pkg_name)
		strings.write_string(&content, "\n")
		if len(imports) > 0 {
			strings.write_string(&content, "\n")
			for line in imports {
				strings.write_string(&content, line)
				strings.write_string(&content, "\n")
			}
		}
		strings.write_string(&content, "\n")
		strings.write_string(&content, text)

		document_changes := make([dynamic]DocumentChange, context.temp_allocator)
		append(&document_changes, CreateFile{kind = "create", uri = target_uri, options = {ignoreIfExists = true}})
		for uri, edits in changes {
			append(&document_changes, TextDocumentEdit{textDocument = {uri = uri}, edits = edits[:]})
		}
		insert := make([]TextEdit, 1, context.temp_allocator)
		insert[0] = {
			newText = strings.to_string(content),
		}
		append(&document_changes, TextDocumentEdit{textDocument = {uri = target_uri}, edits = insert})
		return WorkspaceEdit{documentChanges = document_changes[:]}, true
	}

	h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}
	target := hierarchy_document(&h, target_uri)
	if target == nil || target.ast.pkg_name != pkg_name {
		return {}, false
	}
	target_text := string(target.text[:target.used_text])

	missing := make([dynamic]string, context.temp_allocator)
	for line in imports {
		already := false
		for existing in target.ast.imports {
			already |= strings.contains(line, existing.fullpath)
		}
		if !already {
			append(&missing, line)
		}
	}
	if len(missing) > 0 {
		at := target.ast.pkg_decl.end.offset
		if nl := strings.index_byte(target_text[at:], '\n'); nl >= 0 {
			at += nl
		} else {
			at = len(target_text)
		}
		append_edit(
			changes,
			target,
			at,
			at,
			strings.concatenate(
				{"\n\n", strings.join(missing[:], "\n", context.temp_allocator)},
				context.temp_allocator,
			),
		)
	}
	separator := "\n" if strings.has_suffix(target_text, "\n") else "\n\n"
	append_edit(
		changes,
		target,
		len(target_text),
		len(target_text),
		strings.concatenate({separator, text}, context.temp_allocator),
	)
	return workspace_edit(changes^), true
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

// The imports in used that no other code of document names, leaving out those the file already
// left unused. Any identifier spelled like the import counts as a use, so a shadowing local keeps it.
@(private = "file")
stale_imports :: proc(document: ^Document, decl: ^ast.Value_Decl, used: []Package) -> []Package {
	if len(used) == 0 || document.ast.syntax_error_count > 0 {
		return nil
	}
	names := make(map[string]struct{}, context.temp_allocator)
	visitor := ast.Visitor {
		data = &names,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			if ident, ok := node.derived.(^ast.Ident); ok {
				(^map[string]struct{})(visitor.data)[ident.name] = {}
			}
			return visitor
		},
	}
	for stmt in document.ast.decls {
		if stmt == decl do continue
		if _, is_import := stmt.derived.(^ast.Import_Decl); is_import do continue
		ast.walk(&visitor, stmt)
	}

	stale := make([dynamic]Package, context.temp_allocator)
	for imp in used {
		if imp.base not_in names {
			append(&stale, imp)
		}
	}
	if len(stale) == 0 {
		return nil
	}
	unused_before := find_unused_imports(document, context.temp_allocator)
	#reverse for imp, i in stale {
		if slice.contains(unused_before, imp) do unordered_remove(&stale, i)
	}
	return stale[:]
}

// The byte ranges move deletes from its file, sorted and merged: the declaration and the lines of
// its stale imports with their doc comments. A stale import between blank lines takes one of them along.
@(private = "file")
source_cuts :: proc(move: Move) -> [][2]int {
	src := move.document.ast.src
	cuts := make([dynamic][2]int, context.temp_allocator)
	append(&cuts, [2]int{move.del_start, move.del_end})
	for imp in move.stale_imports {
		start := imp.import_decl.pos.offset
		if imp.import_decl.docs != nil {
			start = min(start, imp.import_decl.docs.pos.offset)
		}
		start = strings.last_index_byte(src[:start], '\n') + 1
		end := imp.import_decl.end.offset
		if nl := strings.index_byte(src[end:], '\n'); nl >= 0 {
			end += nl + 1
		} else {
			end = len(src)
		}
		append(&cuts, [2]int{start, end})
	}
	slice.sort_by(cuts[:], proc(a, b: [2]int) -> bool {return a[0] < b[0]})

	merged := make([dynamic][2]int, context.temp_allocator)
	for cut in cuts {
		if n := len(merged); n > 0 && cut[0] <= merged[n - 1][1] {
			merged[n - 1][1] = max(merged[n - 1][1], cut[1])
		} else {
			append(&merged, cut)
		}
	}
	for &cut in merged {
		if cut == {move.del_start, move.del_end} || cut[0] < 2 || src[cut[0] - 1] != '\n' || src[cut[0] - 2] != '\n' {
			continue
		}
		if cut[1] == len(src) {
			cut[0] -= 1
		} else if src[cut[1]] == '\n' {
			cut[1] += 1
		}
	}
	return merged[:]
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
	} else if matches, err := filepath.glob(
		path.join({dir, "*.odin"}, context.temp_allocator),
		context.temp_allocator,
	); err == nil {
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
