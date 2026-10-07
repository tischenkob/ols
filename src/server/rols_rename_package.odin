package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

import "src:common"

// Comments and directive strings that mention the old name, listed before the rest are only counted.
@(private = "file")
MENTIONS_SHOWN :: 10

// Directives whose string arguments name files or values the rename does not change.
@(private = "file")
STRING_DIRECTIVES :: [?]string{"load", "load_hash", "load_directory", "config"}

// Renames the package in dir to new_name: its package clauses, every import path that steps into dir,
// the `old.x` qualifiers of importers without an alias, and dir itself, to a sibling named new_name.
// The edit puts the text edits first, at the old paths, and the directory rename last. reasons holds one
// cause per refusal and makes ok false. Renaming to the current name gives an empty edit, a no-op.
// files, when given, replaces both the directory listing and the workspace walk.
rename_package :: proc(
	dir, new_name: string,
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

	dir, _ := filepath.replace_separators(dir, '/', context.temp_allocator)
	dir = path.clean(dir)
	old_name := path.base(dir)
	check_package_location(&out, dir, config)
	sources, listed := package_sources(&out, dir, files)
	if !listed || len(out) > 0 {
		return {}, {}, out[:], false
	}
	if new_name == old_name {
		return {}, {}, {}, true
	}

	if check_new_name(&out, new_name) && is_builtin_name(new_name, sources[0].fullpath) {
		append(&out, fmt.tprintf("`%s` is a builtin name, which the import would shadow in each importer", new_name))
	}
	new_dir := path.join({path.dir(dir), new_name})
	if os.exists(new_dir) {
		append(&out, fmt.tprintf("%s already exists", new_dir))
	}

	r := Package_Rename {
		real_dir = canonical_dir(dir),
		old_name = old_name,
		new_name = new_name,
		config   = config,
		reasons  = &out,
		edits    = make(map[string][dynamic]TextEdit),
	}

	// The clauses of dir; each file must name the directory, with or without `_test`.
	documents := make([dynamic]^Document)
	for source in sources {
		document, parsed := parse_package_file(source, config)
		if !parsed {
			append(&out, fmt.tprintf("cannot parse %s", source.fullpath))
			continue
		}
		clause := document.ast.pkg_decl
		suffix := "_test" if strings.has_suffix(clause.name, "_test") else ""
		if strings.trim_suffix(clause.name, "_test") != old_name {
			append(
				&out,
				fmt.tprintf(
					"%s:%d:%d declares `package %s`, but Odin imports the package by its directory name `%s`; make them match first",
					source.fullpath,
					clause.pos.line,
					clause.pos.column,
					clause.name,
					old_name,
				),
			)
			continue
		}
		add_edit(
			&r,
			document.uri.uri,
			text_range(clause.pos, clause.name, document.ast.src),
			strings.concatenate({new_name, suffix}),
		)
		append(&documents, new_clone(document))
	}
	if len(out) > 0 {
		return {}, {}, out[:], false
	}

	// Every other workspace file that mentions the old name may import it.
	for file in workspace_odin_files("", files) {
		if is_source(sources, file.fullpath) {
			continue
		}
		data: []byte
		defer delete(data)
		text := file.text
		if text == "" {
			read, err := os.read_entire_file(file.fullpath, context.allocator)
			if err != nil {
				continue
			}
			data, text = read, string(read)
		}
		if !contains_word(text, old_name) && !imports_into(&r, file.fullpath, text) {
			continue
		}
		document, parsed := parse_package_file({file.fullpath, text}, config)
		if !parsed {
			append(
				&r.warnings,
				fmt.tprintf(
					"cannot parse %s, which mentions or imports `%s`; the rename does not change it",
					file.fullpath,
					old_name,
				),
			)
			continue
		}
		append(&documents, new_clone(document))
	}

	for document in documents {
		rewrite_importer(&r, document)
	}
	if len(out) > 0 {
		return {}, {}, out[:], false
	}

	uris, _ := slice.map_keys(r.edits)
	slice.sort(uris)
	changes := make([dynamic]DocumentChange)
	for uri in uris {
		append(&changes, TextDocumentEdit{textDocument = {uri = uri}, edits = r.edits[uri][:]})
	}
	append(
		&changes,
		RenameFile {
			kind = "rename",
			oldUri = common.create_uri(dir, context.temp_allocator).uri,
			newUri = common.create_uri(new_dir, context.temp_allocator).uri,
		},
	)
	edit.documentChanges = changes[:]

	all_warnings := make([dynamic]string)
	append(&all_warnings, ..r.warnings[:])
	append(&all_warnings, ..skipped_files_warning(old_name, config, mentions_package))
	append(&all_warnings, ..mention_warnings(documents[:], old_name))
	return edit, all_warnings[:], {}, true
}

@(private = "file")
Package_Rename :: struct {
	real_dir: string, // dir with symlinks resolved, to compare resolved import paths
	old_name: string,
	new_name: string,
	config:   ^common.Config,
	reasons:  ^[dynamic]string,
	edits:    map[string][dynamic]TextEdit,
	warnings: [dynamic]string,
}

@(private = "file")
add_edit :: proc(r: ^Package_Rename, uri: string, range: common.Range, text: string) {
	list := r.edits[uri] or_else make([dynamic]TextEdit)
	append(&list, TextEdit{range = range, newText = text})
	r.edits[uri] = list
}

// The range of text where it starts at pos in src.
@(private = "package")
text_range :: proc(pos: tokenizer.Pos, text, src: string) -> common.Range {
	end := pos
	end.offset += len(text)
	end.column += len(text)
	return common.get_token_range(ast.Node{pos = pos, end = end}, src)
}

// Whether p is dir or lies below it; both use forward slashes.
at_or_below :: proc(p, dir: string) -> bool {
	return p == dir || (len(p) > len(dir) && p[len(dir)] == '/' && strings.has_prefix(p, dir))
}

@(private = "file")
is_source :: proc(sources: []Package_File, fullpath: string) -> bool {
	for source in sources {
		if source.fullpath == fullpath {
			return true
		}
	}
	return false
}

// The .odin files directly in dir with their texts, from files when given, else from disk. Appends a cause
// when dir is not a directory of .odin files.
@(private = "file")
package_sources :: proc(out: ^[dynamic]string, dir: string, files: []Package_File) -> ([]Package_File, bool) {
	sources := make([dynamic]Package_File)
	if len(files) > 0 {
		for file in files {
			if path.dir(file.fullpath) == dir {
				append(&sources, file)
			}
		}
	} else if !os.is_directory(dir) {
		append(out, fmt.tprintf("%s is not a directory", dir))
		return {}, false
	} else {
		matches, _ := filepath.glob(path.join({dir, "*.odin"}), context.temp_allocator)
		slice.sort(matches)
		for match in matches {
			data, err := os.read_entire_file(match, context.temp_allocator)
			if err != nil {
				append(out, fmt.tprintf("cannot read %s: %v", match, err))
				return {}, false
			}
			slashed, _ := filepath.replace_separators(match, '/', context.temp_allocator)
			append(&sources, Package_File{slashed, string(data)})
		}
	}
	if len(sources) == 0 {
		append(out, fmt.tprintf("%s contains no .odin files", dir))
		return {}, false
	}
	return sources[:], true
}

// Appends a cause when dir is the workspace root, outside the workspace folders, in core:, vendor: or
// base:, or holds the root of a collection, which the rename would leave pointing at nothing.
@(private = "file")
check_package_location :: proc(out: ^[dynamic]string, dir: string, config: ^common.Config) {
	is_root, library := check_dir_location(out, dir, config)
	if library {
		return
	}
	if is_root {
		append(out, fmt.tprintf("%s is the workspace root", dir))
	}
	for name, root in config.collections {
		if _, inside := relative_dir(dir, root); inside {
			append(
				out,
				fmt.tprintf("the collection `%s` points into %s; renaming the directory would break it", name, dir),
			)
		}
	}
}

// Rewrites the import paths of document that step into the package directory and, for an import of the
// package itself without an alias, every qualifier that resolves to it. Appends a cause for an import that
// resolves into the directory, with symlinks resolved, when the walk over its segments finds no segment
// to rename: a symlink in the path would otherwise leave it pointing at nothing.
@(private = "file")
rewrite_importer :: proc(r: ^Package_Rename, document: ^Document) {
	src := document.ast.src
	for imp in document.ast.imports {
		new_path, final, changed := rewrite_import_path(r, document, imp)
		if changed {
			add_edit(r, document.uri.uri, text_range(imp.relpath.pos, imp.relpath.text, src), new_path)
		}
		// parse_imports drops an import with an unknown collection, which then resolves nowhere.
		pkg := imported_package(document, imp) or_continue
		target := canonical_dir(pkg.name)
		// A walk that ends in the directory, as a relative import from inside it that stays there does, moves
		// with it, so its target is unaffected. One that leaves and comes back through a symlink would dangle.
		if !changed && at_or_below(target, r.real_dir) && !at_or_below(final, r.real_dir) {
			append(
				r.reasons,
				fmt.tprintf(
					"%s:%d:%d: cannot rewrite import path %s, which resolves into %s",
					document.fullpath,
					imp.relpath.pos.line,
					imp.relpath.pos.column,
					imp.relpath.text,
					r.real_dir,
				),
			)
		}
		// An import without an alias binds the directory name, whatever its path says. Its qualifiers are
		// renamed, refused where the new name is already bound in the importer or a local would capture it.
		if target == r.real_dir && imp.name.text == "" {
			check_import_name(r.reasons, document, imp, r.new_name, " of an importer")
			for range in import_qualifiers(document, r.old_name, r.new_name, r.real_dir, r.reasons, &r.warnings) {
				add_edit(r, document.uri.uri, range, r.new_name)
			}
		}
	}
}

// The collection prefix with its colon, the rest of the path, and the directory the rest starts at: the
// collection root, or the directory of file for a relative path. Fails on an unknown collection.
@(private = "package")
split_import_path :: proc(
	config: ^common.Config,
	file, body: string,
) -> (
	prefix: string,
	rel: string,
	start: string,
	ok: bool,
) {
	if i := strings.index_byte(body, ':'); i > 0 {
		root := config.collections[body[:i]] or_return
		return body[:i + 1], body[i + 1:], root, true
	}
	return "", body, path.dir(file, context.temp_allocator), true
}

// Whether an import of text, the source of file, resolves into the package directory with symlinks
// resolved, for a file whose text never names the package, as an import through a symlink does not.
@(private = "file")
imports_into :: proc(r: ^Package_Rename, file, text: string) -> bool {
	// rename-package refuses a directory in core:, vendor: or base:, so no library import can reach it.
	for dir in scan_import_dirs(r.config, file, text, skip_libraries = true) {
		if at_or_below(dir, r.real_dir) {
			return true
		}
	}
	return false
}

// The directories, with symlinks resolved, that the imports of text, the source of file, name. Scans
// tokens without parsing, so a file that does not parse still counts. Skips foreign imports, unknown
// collections and, with skip_libraries, core:, vendor: and base: before their realpath.
@(private = "file")
scan_import_dirs :: proc(config: ^common.Config, file, text: string, skip_libraries := false) -> []string {
	dirs := make([dynamic]string, context.temp_allocator)
	libraries := LIBRARY_COLLECTIONS
	t: tokenizer.Tokenizer
	tokenizer.init(&t, text, file, proc(pos: tokenizer.Pos, msg: string, args: ..any) {})
	previous: tokenizer.Token
	in_import := false
	for token := tokenizer.scan(&t); token.kind != .EOF; previous, token = token, tokenizer.scan(&t) {
		#partial switch token.kind {
		case .Import:
			in_import = previous.kind != .Foreign
		case .Ident, .Comment:
		case .String:
			if in_import && len(token.text) >= 2 {
				prefix, rel, start, known := split_import_path(config, file, token.text[1:len(token.text) - 1])
				library := skip_libraries && slice.contains(libraries[:], strings.trim_suffix(prefix, ":"))
				if known && !library {
					append(&dirs, canonical_dir(path.join({start, rel}, context.temp_allocator)))
				}
			}
			in_import = false
		case:
			in_import = false
		}
	}
	return dirs[:]
}

// The imports of the workspace files, read once for any number of graph_importers walks.
Import_Graph :: struct {
	// Canonical imported directory to the directories of the files that import it.
	importers_of: map[string][dynamic]string,
	// Directory of a file to its canonical form.
	canonical:    map[string]string,
}

// The imports of every workspace file. One scan reads each file once; the walk applies the workspace filter.
// files, when given, replaces the walk, and a file with empty text is read from disk.
import_graph :: proc(config: ^common.Config, files: []Package_File = {}) -> Import_Graph {
	importers_of := make(map[string][dynamic]string, context.temp_allocator)
	canonical := make(map[string]string, context.temp_allocator)
	for file in workspace_odin_files("", files) {
		dir := path.dir(file.fullpath, context.temp_allocator)
		if dir not_in canonical {
			canonical[dir] = canonical_dir(dir)
		}
		data: []byte
		defer delete(data)
		text := file.text
		if text == "" {
			read, err := os.read_entire_file(file.fullpath, context.allocator)
			if err != nil {
				continue
			}
			data, text = read, string(read)
		}
		for imported in scan_import_dirs(config, file.fullpath, text) {
			list, found := importers_of[imported]
			if !found {
				list = make([dynamic]string, context.temp_allocator)
			}
			append(&list, dir)
			importers_of[imported] = list
		}
	}
	return {importers_of, canonical}
}

// The directories of the workspace files in graph outside dirs that import a package in dirs, directly or
// through other importers. An edit of dirs can break these importers without touching them: a type that b
// re-exports from c reaches a, which imports b.
graph_importers :: proc(graph: Import_Graph, dirs: []string) -> []string {
	targets := make(map[string]bool, context.temp_allocator)
	for dir in dirs {
		targets[canonical_dir(dir)] = true
	}
	// Walk from the targets to their importers, then to theirs. visited makes a cycle end.
	importers := make([dynamic]string, context.temp_allocator)
	visited := make(map[string]bool, context.temp_allocator)
	pending := make([dynamic]string, context.temp_allocator)
	for target in targets {
		visited[target] = true
		append(&pending, target)
	}
	for len(pending) > 0 {
		current := pop(&pending)
		// A range over the map index itself loops forever for a key that is missing, so the lookup comes first.
		importing := graph.importers_of[current]
		for dir in importing {
			real := graph.canonical[dir]
			if !visited[real] {
				visited[real] = true
				append(&importers, dir)
				append(&pending, real)
			}
		}
	}
	slice.sort(importers[:])
	return importers[:]
}

// The package that parse_imports resolved for imp.
@(private = "file")
imported_package :: proc(document: ^Document, imp: ^ast.Import_Decl) -> (pkg: Package, ok: bool) {
	for candidate in document.imports {
		if candidate.import_decl == imp {
			return candidate, true
		}
	}
	return {}, false
}

// The import path of imp with the segment that steps into the package directory renamed, quotes included,
// and final, the directory the walk over its segments ends at. Each segment is followed from the directory
// the path starts at, so a relative path that only leaves the package with `..` stays as it is. Only the
// start has its symlinks resolved. A segment ends at `/` or `\`, and each separator is kept as written; the
// empty segment between an escaped `\\` is skipped.
@(private = "file")
rewrite_import_path :: proc(
	r: ^Package_Rename,
	document: ^Document,
	imp: ^ast.Import_Decl,
) -> (
	new_path: string,
	final: string,
	changed: bool,
) {
	quoted := imp.relpath.text
	if len(quoted) < 2 {
		return
	}
	body := quoted[1:len(quoted) - 1]
	prefix, rel, start := split_import_path(r.config, document.fullpath, body) or_return

	b := strings.builder_make()
	strings.write_string(&b, quoted[:1])
	strings.write_string(&b, prefix)
	current := canonical_dir(start)
	rest := rel
	for {
		i := strings.index_any(rest, `/\`)
		segment := rest if i < 0 else rest[:i]
		switch segment {
		case "", ".":
		case "..":
			current = path.dir(current)
		case:
			current = path.join({current, segment})
			if current == r.real_dir {
				segment = r.new_name
				changed = true
			}
		}
		strings.write_string(&b, segment)
		if i < 0 {
			break
		}
		strings.write_byte(&b, rest[i])
		rest = rest[i + 1:]
	}
	strings.write_string(&b, quoted[:1])
	return strings.to_string(b), current, changed
}

// Appends a cause for each binding of new_name in document that the import imp, named new_name, would
// collide with: another import, a file-scope declaration, or a declaration elsewhere in the package.
// whose ends the scope in a cause, as ` of an importer` for rename-package.
@(private = "package")
check_import_name :: proc(
	reasons: ^[dynamic]string,
	document: ^Document,
	imp: ^ast.Import_Decl,
	new_name, whose: string,
) {
	for other in document.imports {
		if other.import_decl != imp && other.base == new_name {
			append(
				reasons,
				fmt.tprintf(
					"%s:%d:%d: the file already imports a package as `%s`",
					document.fullpath,
					other.import_decl.pos.line,
					other.import_decl.pos.column,
					new_name,
				),
			)
		}
	}
	in_file := false
	for decl in top_level_value_decls(document.ast) {
		for name in decl.names {
			if ident, is_ident := name.derived.(^ast.Ident); is_ident && ident.name == new_name {
				in_file = true
				append(
					reasons,
					fmt.tprintf(
						"%s:%d:%d: `%s` is already declared at file scope%s",
						document.fullpath,
						ident.pos.line,
						ident.pos.column,
						new_name,
						whose,
					),
				)
			}
		}
	}
	if other, found := lookup(new_name, document.package_name, document.fullpath);
	   found && !(in_file && strings.equal_fold(other.uri, document.uri.uri)) && !is_builtin_pkg(other.pkg) {
		file := common.uri_to_path(other.uri, context.temp_allocator)
		line, column := other.range.start.line + 1, other.range.start.character + 1
		append(
			reasons,
			fmt.tprintf("%s:%d:%d: `%s` is already declared in the package%s", file, line, column, new_name, whose),
		)
	}
}

// The ranges of the qualifiers of document named old_name that resolve to the package in real_dir, which
// has its symlinks resolved. Appends a warning for each qualifier that does not resolve, and a cause for
// each one that a local named new_name would capture.
@(private = "package")
import_qualifiers :: proc(
	document: ^Document,
	old_name, new_name, real_dir: string,
	reasons, warnings: ^[dynamic]string,
) -> []common.Range {
	ranges := make([dynamic]common.Range)
	for qualifier in qualifier_uses(document, old_name) {
		ident := qualifier.ident
		label := fmt.tprintf("%s.%s", old_name, qualifier.field) if qualifier.field != "" else old_name
		at := common.get_token_range(ident^, document.ast.src)
		symbol, found := resolve_name_at(document, at.start, ident.pos.offset, old_name)
		if !found {
			append(
				warnings,
				fmt.tprintf(
					"%s:%d:%d: cannot resolve `%s`, so the rename does not change it",
					document.fullpath,
					ident.pos.line,
					ident.pos.column,
					label,
				),
			)
			continue
		}
		if symbol.type != .Package || canonical_dir(symbol.pkg) != real_dir {
			continue
		}
		if other, bound := resolve_name_at(document, at.start, ident.pos.offset, new_name);
		   bound && .Local in other.flags {
			append(
				reasons,
				fmt.tprintf(
					"%s:%d:%d: `%s` is a local here, declared at %s, so it would capture the qualifier of `%s`",
					document.fullpath,
					ident.pos.line,
					ident.pos.column,
					new_name,
					declared_at(other),
					label,
				),
			)
		}
		append(&ranges, at)
	}
	return ranges[:]
}

// A use of the package name: the `name` of `name.x`, with the field x, or the value of an alias
// declaration `alias :: name` or the argument of `#defined(name)`, with an empty field.
@(private = "package")
Qualifier :: struct {
	ident: ^ast.Ident,
	field: string,
}

// Every qualifier of document whose identifier is name: a selector's left side, the value of a
// declaration and the argument of `#defined`. Odin rejects an import name anywhere else.
@(private = "package")
qualifier_uses :: proc(document: ^Document, name: string) -> []Qualifier {
	Found :: struct {
		name:       string,
		qualifiers: [dynamic]Qualifier,
	}
	found := Found{name, make([dynamic]Qualifier)}
	visitor := ast.Visitor {
		visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			found := (^Found)(v.data)
			#partial switch n in node.derived {
			case ^ast.Selector_Expr:
				if n.expr != nil {
					if ident, is_ident := n.expr.derived.(^ast.Ident); is_ident && ident.name == found.name {
						append(&found.qualifiers, Qualifier{ident, n.field.name if n.field != nil else ""})
					}
				}
			case ^ast.Call_Expr:
				// `#defined(old)`, which compiles inside a procedure, is true while the import binds old.
				directive, is_directive := n.expr.derived.(^ast.Basic_Directive)
				if is_directive && directive.name == "defined" && len(n.args) == 1 {
					if ident, is_ident := n.args[0].derived.(^ast.Ident); is_ident && ident.name == found.name {
						append(&found.qualifiers, Qualifier{ident, ""})
					}
				}
			case ^ast.Value_Decl:
				// `alias :: old` names the package by its bare name.
				for value in n.values {
					if ident, is_ident := value.derived.(^ast.Ident); is_ident && ident.name == found.name {
						append(&found.qualifiers, Qualifier{ident, ""})
					}
				}
			}
			return v
		},
		data = &found,
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	return found.qualifiers[:]
}

// Every foreign import of document, those in `when` blocks included.
@(private = "file")
foreign_imports :: proc(document: ^Document) -> []^ast.Foreign_Import_Decl {
	found := make([dynamic]^ast.Foreign_Import_Decl)
	visitor := ast.Visitor {
		visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			if decl, is_decl := node.derived.(^ast.Foreign_Import_Decl); is_decl {
				append((^[dynamic]^ast.Foreign_Import_Decl)(v.data), decl)
			}
			return v
		},
		data = &found,
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	return found[:]
}

// Whether text mentions the package name as a qualifier `name.` or as an import path segment.
@(private = "file")
mentions_package :: proc(text, name: string) -> bool {
	for start := 0; start < len(text); {
		i := strings.index(text[start:], name)
		if i < 0 {
			return false
		}
		i += start
		end := i + len(name)
		before := text[i - 1] if i > 0 else 0
		after := text[end] if end < len(text) else 0
		whole := !is_ident_rune(rune(before)) && !is_ident_rune(rune(after))
		in_path := before == '/' || before == ':' || before == '"' || after == '/' || after == '"'
		if whole && (after == '.' || in_path) {
			return true
		}
		start = i + 1
	}
	return false
}

// One warning per comment, foreign import path, or #load, #load_hash, #load_directory or #config string of
// documents that mentions name, up to MENTIONS_SHOWN, then one that counts the rest.
@(private = "file")
mention_warnings :: proc(documents: []^Document, name: string) -> []string {
	warnings := make([dynamic]string)
	hidden := 0
	mention :: proc(warnings: ^[dynamic]string, hidden: ^int, file: string, pos: tokenizer.Pos, what, name: string) {
		if len(warnings) == MENTIONS_SHOWN {
			hidden^ += 1
			return
		}
		append(
			warnings,
			fmt.tprintf(
				"%s:%d:%d: the %s mentions `%s`, which rename-package does not change",
				file,
				pos.line,
				pos.column,
				what,
				name,
			),
		)
	}
	directives := STRING_DIRECTIVES
	for document in documents {
		for decl in foreign_imports(document) {
			for expr in decl.fullpaths {
				if lit, is_lit := expr.derived.(^ast.Basic_Lit); is_lit && contains_word(lit.tok.text, name) {
					mention(&warnings, &hidden, document.fullpath, lit.pos, "foreign import path", name)
				}
			}
		}
		t: tokenizer.Tokenizer
		tokenizer.init(&t, document.ast.src, document.fullpath, proc(pos: tokenizer.Pos, msg: string, args: ..any) {})
		directive := false
		depth := 0
		previous: tokenizer.Token
		for token := tokenizer.scan(&t); token.kind != .EOF; previous, token = token, tokenizer.scan(&t) {
			what := ""
			#partial switch token.kind {
			case .Comment:
				what = "comment"
			case .Ident:
				if previous.kind == .Hash && slice.contains(directives[:], token.text) {
					directive, depth = true, 0
				}
			case .Open_Paren:
				depth += 1
			case .Close_Paren:
				depth -= 1
				if depth <= 0 {
					directive = false
				}
			case .String:
				if directive && depth > 0 {
					what = "directive string"
				}
			}
			if what != "" && contains_word(token.text, name) {
				mention(&warnings, &hidden, document.fullpath, token.pos, what, name)
			}
		}
	}
	if hidden > 0 {
		append(
			&warnings,
			fmt.tprintf("%d more comments, foreign import paths or directive strings mention `%s`", hidden, name),
		)
	}
	return warnings[:]
}
