package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "src:common"

// Collections that hold the Odin distribution; their declarations are never renamed.
@(private)
LIBRARY_COLLECTIONS :: [?]string{"core", "vendor", "base"}

// Universe constants the checker knows without a declaration in $builtin.
@(private = "file")
BUILTIN_CONSTANTS :: [?]string{"nil", "true", "false"}

@(private = "file")
SKIPPED_FILES_SHOWN :: 10

@(private = "file")
Rename_Target :: struct {
	document: ^Document,
	symbol:   Symbol,
	flag:     ResolveReferenceFlag,
	old_name: string,
	h:        Call_Hierarchy,
}

// Why renaming the symbol at position to new_name is unsafe, one sentence per cause, and warnings that
// do not block it. No reasons and no warnings when the new name equals the old one, so the caller sees
// a no-op. files, when given, replaces the workspace walk.
check_rename :: proc(
	document: ^Document,
	position: common.Position,
	new_name: string,
	config: ^common.Config,
	files: []Package_File = {},
) -> (
	reasons: []string,
	warnings: []string,
) {
	out := make([dynamic]string, context.temp_allocator)
	target := Rename_Target {
		document = document,
		h        = {files, make(map[string]^Document, context.temp_allocator)},
	}
	target.h.documents[document.uri.uri] = document

	if reason, is_import := import_at(document, position); is_import {
		append(&out, reason)
		return out[:], {}
	}
	found, qualifier: bool
	target.symbol, target.flag, target.old_name, qualifier, found = rename_symbol_at(document, position, &target.h)
	if !found {
		append(&out, "no symbol to rename at the position")
		return out[:], {}
	}
	if target.old_name == new_name {
		return {}, {}
	}
	if qualifier {
		append(
			&out,
			fmt.tprintf(
				"`%s` is a package qualifier: use rename-package to rename an import alias or a package",
				target.old_name,
			),
		)
		return out[:], {}
	}

	name_ok := check_new_name(&out, new_name)
	if .Builtin in target.symbol.flags || is_builtin_pkg(target.symbol.pkg) {
		append(&out, fmt.tprintf("`%s` is a builtin and cannot be renamed", target.old_name))
		return out[:], {}
	}
	if reason, library := library_location(target.symbol.uri, config); library {
		append(&out, reason)
	}
	if !name_ok || len(out) > 0 {
		return out[:], {}
	}

	if target.flag == .Identifier && is_builtin_name(new_name, document.fullpath) {
		// Every reference site would report the builtin again.
		append(&out, fmt.tprintf("`%s` is a builtin name, and the rename would shadow it", new_name))
		return out[:], {}
	}
	check_collisions(&out, &target, new_name)
	check_captures(&out, &target, new_name, files)
	return out[:], skipped_files_warning(target.old_name, config)
}

// The cause when position is on an import declaration: its alias or path names a package, not a symbol.
@(private = "file")
import_at :: proc(document: ^Document, position: common.Position) -> (reason: string, ok: bool) {
	offset := common.get_absolute_position(position, document.text[:document.used_text]) or_return
	for imp in document.ast.imports {
		if imp.pos.offset <= offset && offset <= imp.end.offset {
			return "the position is on an import: use rename-package to rename an import alias or a package", true
		}
	}
	return "", false
}

// The symbol the rename at position changes, resolved as get_rename resolves it. qualifier is set on
// the package name of `pkg.name` or on a bare import name; a member of a package keeps the package
// symbol type from resolve_symbol_selector, so the cursor decides. The member of `pkg.name` resolves
// again at its declaration, so it is checked as the identifier it is.
@(private = "file")
rename_symbol_at :: proc(
	document: ^Document,
	position: common.Position,
	h: ^Call_Hierarchy,
) -> (
	symbol: Symbol,
	flag: ResolveReferenceFlag,
	old_name: string,
	qualifier: bool,
	ok: bool,
) {
	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)
	position_context := get_document_position_context(document, position, .Hover) or_return
	ast_context.position_hint = position_context.hint
	ast_context.current_package = ast_context.document_package
	get_globals(document.ast, &ast_context)
	get_locals(&ast_context, &position_context)

	symbol, flag = prepare_references(document, &ast_context, &position_context) or_return
	old_name = get_target_name(&position_context, flag)
	on_field :=
		position_context.selector_expr != nil &&
		!position_in_node(position_context.selector, position_context.position)
	if symbol.type == .Package && on_field {
		decl_document := hierarchy_document(h, symbol.uri)
		if decl_document == nil || decl_document == document {
			return
		}
		return rename_symbol_at(decl_document, symbol.range.start, h)
	}
	qualifier = symbol.type == .Package
	return symbol, flag, old_name, qualifier, old_name != ""
}

// Appends a cause when name is not a plain identifier or is a keyword; ok is false after any cause.
@(private)
check_new_name :: proc(out: ^[dynamic]string, name: string) -> (ok: bool) {
	t: tokenizer.Tokenizer
	tokenizer.init(&t, name, "", proc(pos: tokenizer.Pos, msg: string, args: ..any) {})
	first := tokenizer.scan(&t)
	whole := first.text == name && tokenizer.scan(&t).kind == .EOF
	switch {
	case whole && .B_Keyword_Begin < first.kind && first.kind < .B_Keyword_End:
		append(out, fmt.tprintf("`%s` is a keyword", name))
	case !whole || first.kind != .Ident:
		append(out, fmt.tprintf("`%s` is not a valid Odin identifier", name))
	case name == "_":
		append(out, "`_` is the blank identifier, which cannot be referenced")
	case:
		return true
	}
	return false
}

// A builtin type name, a universe constant, or a declaration in $builtin. Fields and enum members may
// use these names, so only identifier targets check them.
@(private)
is_builtin_name :: proc(name: string, current_file: string) -> bool {
	constants := BUILTIN_CONSTANTS
	if name in keyword_map || slice.contains(constants[:], name) {
		return true
	}
	symbol, found := lookup(name, "$builtin", current_file)
	return found && (is_builtin_pkg(symbol.pkg) || .Builtin in symbol.flags)
}

// The cause when the file of uri is in core:, vendor: or base:, or lies outside every workspace folder.
@(private)
library_location :: proc(uri: string, config: ^common.Config) -> (reason: string, library: bool) {
	file := common.uri_to_path(uri, context.temp_allocator)
	dir := path.dir(file, context.temp_allocator)
	libraries := LIBRARY_COLLECTIONS
	for name, root in config.collections {
		// A package of the collection lies strictly below its root.
		rel, inside := relative_dir(root, dir)
		if inside && rel != "" && slice.contains(libraries[:], name) {
			return fmt.tprintf("the declaration is in %s:%s, a library outside the workspace", name, rel), true
		}
	}
	if len(config.workspace_folders) == 0 {
		return "", false
	}
	for folder in config.workspace_folders {
		root := common.uri_to_path(folder.uri, context.temp_allocator)
		if _, inside := relative_dir(root, dir); inside {
			return "", false
		}
	}
	return fmt.tprintf("the declaration is in %s, outside the workspace folders", file), true
}

// Appends a cause when dir is in core:, vendor: or base:, which sets library and stops there, or lies outside
// every workspace folder. is_root is set when dir is a workspace folder itself.
@(private)
check_dir_location :: proc(out: ^[dynamic]string, dir: string, config: ^common.Config) -> (is_root, library: bool) {
	libraries := LIBRARY_COLLECTIONS
	for name, root in config.collections {
		if rel, inside := relative_dir(root, dir); inside && slice.contains(libraries[:], name) {
			append(out, fmt.tprintf("%s is in %s:%s, a library outside the workspace", dir, name, rel))
			return false, true
		}
	}
	if len(config.workspace_folders) == 0 {
		return
	}
	for folder in config.workspace_folders {
		if rel, inside := relative_dir(common.uri_to_path(folder.uri, context.temp_allocator), dir); inside {
			return rel == "", false
		}
	}
	append(out, fmt.tprintf("%s is outside the workspace folders", dir))
	return
}

// dir relative to root with forward slashes, "" for root itself; inside is false when dir is not under root.
// Both resolve symlinks first, as the workspace filter does, so /var and /private/var compare equal.
@(private)
relative_dir :: proc(root, dir: string) -> (rel: string, inside: bool) {
	root := strings.trim_right(canonical_dir(root), "/")
	dir := canonical_dir(dir)
	prefix_matches: bool
	when ODIN_OS == .Windows {
		prefix_matches = len(dir) >= len(root) && strings.equal_fold(dir[:len(root)], root)
	} else {
		prefix_matches = strings.has_prefix(dir, root)
	}
	if !prefix_matches {
		return "", false
	}
	if len(dir) == len(root) {
		return "", true
	}
	if dir[len(root)] == '/' {
		return dir[len(root) + 1:], true
	}
	return "", false
}

// The real path of dir with forward slashes, or dir cleaned when it does not exist.
@(private)
canonical_dir :: proc(dir: string) -> string {
	real, err := os.get_absolute_path(dir, context.temp_allocator)
	if err != nil {
		real = dir
	}
	slashed, _ := filepath.replace_separators(real, '/', context.temp_allocator)
	return path.clean(slashed, context.temp_allocator)
}

// Appends a cause for each declaration that already uses new_name in the scope that declares the target.
@(private = "file")
check_collisions :: proc(out: ^[dynamic]string, target: ^Rename_Target, new_name: string) {
	symbol := target.symbol
	decl_document := hierarchy_document(&target.h, symbol.uri)
	if decl_document == nil {
		return
	}
	decl_offset, offset_ok := common.get_absolute_position(
		symbol.range.start,
		decl_document.text[:decl_document.used_text],
	)
	if !offset_ok {
		return
	}

	switch {
	case target.flag == .Field:
		if members, found := sibling_members(decl_document, decl_offset); found {
			for ident in members {
				if ident.name == new_name {
					append(
						out,
						fmt.tprintf(
							"`%s` is already a member of the same type at %s",
							new_name,
							ident_text(decl_document, ident),
						),
					)
				}
			}
		}
	case .Local in symbol.flags:
		for ident in scope_declarations(decl_document, decl_offset) {
			if ident.name == new_name && ident.pos.offset != decl_offset {
				append(
					out,
					fmt.tprintf(
						"`%s` is already declared in the same scope at %s",
						new_name,
						ident_text(decl_document, ident),
					),
				)
			}
		}
	case:
		in_file := false
		for decl in top_level_value_decls(decl_document.ast) {
			for name in decl.names {
				if ident, ok := name.derived.(^ast.Ident); ok && ident.name == new_name {
					in_file = true
					append(
						out,
						fmt.tprintf(
							"`%s` is already declared in the package at %s%s",
							new_name,
							ident_text(decl_document, ident),
							" (in a when branch)" if in_when(decl_document.ast, ident.pos.offset) else "",
						),
					)
				}
			}
		}
		other, found := lookup(new_name, symbol.pkg, decl_document.fullpath)
		if found && !(in_file && strings.equal_fold(other.uri, decl_document.uri.uri)) {
			append(out, fmt.tprintf("`%s` is already declared in the package at %s", new_name, declared_at(other)))
		}
	}
}

// Whether offset lies inside a file-scope `when` statement.
@(private = "file")
in_when :: proc(file: ast.File, offset: int) -> bool {
	for stmt in file.decls {
		if _, is_when := stmt.derived.(^ast.When_Stmt);
		   is_when && stmt.pos.offset <= offset && offset < stmt.end.offset {
			return true
		}
	}
	return false
}

// Appends a cause for each reference site where new_name already means something else, and for each use
// of new_name that the renamed local would capture.
@(private = "file")
check_captures :: proc(out: ^[dynamic]string, target: ^Rename_Target, new_name: string, files: []Package_File) {
	if target.flag != .Identifier {
		return
	}
	symbol := target.symbol
	document := target.document
	local := .Local in symbol.flags

	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)
	get_globals(document.ast, &ast_context)
	ast_context.current_package = ast_context.document_package
	locations, _ := find_symbol_references(
		document,
		&ast_context,
		symbol,
		.Identifier,
		target_name = target.old_name,
		files = files,
	)

	// A reference that new_name would resolve elsewhere.
	for location in locations {
		if strings.equal_fold(location.uri, symbol.uri) && location.range == symbol.range {
			continue
		}
		site := hierarchy_document(&target.h, location.uri)
		if site == nil {
			continue
		}
		offset, offset_ok := common.get_absolute_position(location.range.start, site.text[:site.used_text])
		if !offset_ok || is_qualified(string(site.text[:site.used_text]), offset) {
			continue
		}
		other := resolve_name_at(site, location.range.start, offset, new_name) or_continue
		if same_symbol(other, symbol) {
			continue
		}
		captured: bool
		if local {
			// A later local is the inner one, and get_local prefers it.
			captured = .Local in other.flags && range_after(other.range, symbol.range)
		} else {
			// A global of the same package is a collision, already reported.
			captured = .Local in other.flags || other.type == .Package || other.pkg != symbol.pkg
		}
		if captured {
			append(
				out,
				fmt.tprintf(
					"at %s `%s` already refers to %s, so the renamed reference would resolve to it",
					location_text(location, site),
					new_name,
					describe(other, new_name),
				),
			)
		}
	}

	if !local {
		return
	}
	// A use of new_name that the renamed local would shadow. Locals stay in their file.
	for key, hit in resolve_entire_file_for_references(document, context.temp_allocator, .Identifier, new_name) {
		// A selector field, composite-literal key or named argument is keyed by its parent node.
		if key != uintptr(hit.node) {
			continue
		}
		ident := hit.node.derived.(^ast.Ident) or_continue
		if ident.name != new_name {
			continue
		}
		other := hit.symbol^
		if .Local in other.flags && !range_after(symbol.range, other.range) {
			continue
		}
		at := common.get_token_range(ident^, document.ast.src)
		visible := resolve_name_at(document, at.start, ident.pos.offset, target.old_name) or_continue
		if same_symbol(visible, symbol) {
			append(
				out,
				fmt.tprintf(
					"at %s `%s` refers to %s, which the renamed local would shadow",
					location_text(common.Location{uri = document.uri.uri, range = at}, document),
					new_name,
					describe(other, new_name),
				),
			)
		}
	}
}

// What name resolves to at position in document, with the locals visible there.
@(private)
resolve_name_at :: proc(
	document: ^Document,
	position: common.Position,
	offset: int,
	name: string,
) -> (
	symbol: Symbol,
	ok: bool,
) {
	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)
	position_context := get_document_position_context(document, position, .Hover) or_return
	ast_context.position_hint = position_context.hint
	ast_context.current_package = ast_context.document_package
	get_globals(document.ast, &ast_context)
	get_locals(&ast_context, &position_context)

	ident: ast.Ident
	ident.name = name
	ident.pos = {
		file   = document.ast.fullpath,
		offset = offset,
	}
	return resolve_location_identifier(&ast_context, ident)
}

// Whether the identifier at offset follows a `.`, as the field of a package qualifier does; the `..`
// of a spread argument does not qualify it.
@(private = "file")
is_qualified :: proc(src: string, offset: int) -> bool {
	before := strings.trim_right_space(src[:offset])
	return strings.has_suffix(before, ".") && !strings.has_suffix(before, "..")
}

@(private = "file")
same_symbol :: proc(a, b: Symbol) -> bool {
	return a.range == b.range && strings.equal_fold(a.uri, b.uri)
}

@(private = "file")
range_after :: proc(a, b: common.Range) -> bool {
	return a.start.line > b.start.line || (a.start.line == b.start.line && a.start.character > b.start.character)
}

// The import, or name with where it is declared.
@(private = "file")
describe :: proc(symbol: Symbol, name: string) -> string {
	if symbol.type == .Package {
		return fmt.tprintf("the import `%s`", name)
	}
	return fmt.tprintf("`%s` declared at %s", name, declared_at(symbol))
}

// FILE:LINE of a symbol's declaration.
@(private)
declared_at :: proc(symbol: Symbol) -> string {
	return fmt.tprintf("%s:%d", common.uri_to_path(symbol.uri, context.temp_allocator), symbol.range.start.line + 1)
}

@(private = "file")
ident_text :: proc(document: ^Document, ident: ^ast.Ident) -> string {
	return fmt.tprintf("%s:%d:%d", document.fullpath, ident.pos.line, ident.pos.column)
}

// The members of the struct, enum or bit_field type that declares the member named at offset.
@(private = "file")
sibling_members :: proc(document: ^Document, offset: int) -> (members: []^ast.Ident, found: bool) {
	for at in nodes_at(document.ast.decls[:], offset) {
		list: []^ast.Ident
		#partial switch n in at.node.derived {
		case ^ast.Struct_Type:
			list, _ = type_members(n)
		case ^ast.Enum_Type:
			list, _ = type_members(n)
		case ^ast.Bit_Field_Type:
			list, _ = type_members(n)
		}
		for ident in list {
			if ident.pos.offset == offset {
				return list, true
			}
		}
	}
	return {}, false
}

// The names declared directly in the innermost scope around offset: a block with the parameters of its
// procedure, a procedure's parameters and body, or a statement's loop values and init declaration.
@(private = "file")
scope_declarations :: proc(document: ^Document, offset: int) -> []^ast.Ident {
	names := make([dynamic]^ast.Ident, context.temp_allocator)
	chain := nodes_at(document.ast.decls[:], offset)
	#reverse for at in chain {
		#partial switch n in at.node.derived {
		case ^ast.Block_Stmt:
			collect_stmts(&names, n.stmts)
			if at.parent != nil {
				if lit, is_lit := at.parent.derived.(^ast.Proc_Lit); is_lit && lit.body == n {
					collect_params(&names, lit)
				}
			}
			return names[:]
		case ^ast.Proc_Lit:
			collect_params(&names, n)
			if body, is_block := n.body.derived.(^ast.Block_Stmt); n.body != nil && is_block {
				collect_stmts(&names, body.stmts)
			}
			return names[:]
		case ^ast.Range_Stmt:
			collect_exprs(&names, n.vals)
			return names[:]
		case ^ast.For_Stmt:
			collect_stmts(&names, {n.init})
			return names[:]
		case ^ast.If_Stmt:
			collect_stmts(&names, {n.init})
			return names[:]
		case ^ast.Switch_Stmt:
			collect_stmts(&names, {n.init})
			return names[:]
		}
	}
	return names[:]

	collect_stmts :: proc(names: ^[dynamic]^ast.Ident, stmts: []^ast.Stmt) {
		for stmt in stmts {
			if stmt == nil {
				continue
			}
			if decl, ok := stmt.derived.(^ast.Value_Decl); ok {
				collect_exprs(names, decl.names)
			}
		}
	}
	collect_params :: proc(names: ^[dynamic]^ast.Ident, lit: ^ast.Proc_Lit) {
		if lit.type == nil {
			return
		}
		for list in ([]^ast.Field_List{lit.type.params, lit.type.results}) {
			if list != nil {
				for field in list.list {
					collect_exprs(names, field.names)
				}
			}
		}
	}
	collect_exprs :: proc(names: ^[dynamic]^ast.Ident, exprs: []^ast.Expr) {
		for expr in exprs {
			if ident, ok := expr.derived.(^ast.Ident); ok {
				append(names, ident)
			}
		}
	}
}

// A warning naming the workspace files the gitignore, exclude or include filter skipped that mention
// word, since actor does not change them. Empty when there are none. dir, when given, limits the files
// to those at or below it.
@(private)
skipped_files_warning :: proc(
	word: string,
	config: ^common.Config,
	mentions: proc(text, word: string) -> bool = contains_word,
	actor := "the rename",
	dir := "",
) -> []string {
	skipped := make([dynamic]string, context.temp_allocator)
	when !ODIN_TEST {
		// Files the walk with the filter keeps, and files already read; overlapping folders share both.
		seen := make(map[string]struct{}, context.temp_allocator)
		for folder in config.workspace_folders {
			uri, _ := common.parse_uri(folder.uri, context.temp_allocator)
			filter := common.workspace_filter_make(uri.path, config, context.temp_allocator)
			all := make([dynamic]string, context.temp_allocator)
			kept := make([dynamic]string, context.temp_allocator)
			common.search_for_odin_files(uri.path, "", dir_blacklist, &all)
			common.search_for_odin_files(uri.path, "", dir_blacklist, &kept, &filter)
			for file in kept {
				seen[file] = {}
			}
			for file in all {
				if file in seen {
					continue
				}
				seen[file] = {}
				if dir != "" {
					if _, inside := relative_dir(dir, path.dir(file, context.temp_allocator)); !inside do continue
				}
				// Each file is freed before the next one is read, so the memory stays bounded.
				data, err := os.read_entire_file(file, context.allocator)
				if err == nil {
					if mentions(string(data), word) {
						append(&skipped, file)
					}
					delete(data)
				}
			}
		}
	}
	if len(skipped) == 0 {
		return {}
	}
	slice.sort(skipped[:])
	shown := skipped[:min(len(skipped), SKIPPED_FILES_SHOWN)]
	list := strings.join(shown, ", ", context.temp_allocator)
	if len(skipped) > len(shown) {
		list = fmt.tprintf("%s and %d more", list, len(skipped) - len(shown))
	}
	warnings := make([]string, 1, context.temp_allocator)
	warnings[0] = fmt.tprintf(
		"%d workspace file%s skipped by the gitignore, exclude or include filter contain%s `%s`, and %s does not change %s: %s",
		len(skipped),
		"" if len(skipped) == 1 else "s",
		"s" if len(skipped) == 1 else "",
		word,
		actor,
		"it" if len(skipped) == 1 else "them",
		list,
	)
	return warnings
}

// Whether word occurs in text with no identifier character on either side.
@(private)
contains_word :: proc(text, word: string) -> bool {
	return index_word(text, word, 0) >= 0
}

// text with with in place of each occurrence of word that contains_word would find.
replace_word :: proc(text, word, with: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	last := 0
	for i := index_word(text, word, 0); i >= 0; i = index_word(text, word, last) {
		strings.write_string(&b, text[last:i])
		strings.write_string(&b, with)
		last = i + len(word)
	}
	strings.write_string(&b, text[last:])
	return strings.to_string(b)
}

// The offset of the first occurrence of word at or after from with no identifier character on either side, or -1.
@(private)
index_word :: proc(text, word: string, from: int) -> int {
	if word == "" {
		return -1
	}
	for start := from; start <= len(text); {
		i := strings.index(text[start:], word)
		if i < 0 {
			return -1
		}
		i += start
		end := i + len(word)
		before, _ := utf8.decode_last_rune_in_string(text[:i])
		after, _ := utf8.decode_rune_in_string(text[end:])
		if (i == 0 || !is_ident_rune(before)) && (end == len(text) || !is_ident_rune(after)) {
			return i
		}
		start = i + 1
	}
	return -1
}

@(private)
is_ident_rune :: proc(r: rune) -> bool {
	return r == '_' || ('0' <= r && r <= '9') || ('a' <= r && r <= 'z') || ('A' <= r && r <= 'Z') || r >= 0x80
}
