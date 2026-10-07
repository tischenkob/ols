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
	variants: []Decl_Variant, // the platform variants that the rename changes too
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

	if _, warnings, reasons, on_import_name := rename_import(document, position, new_name); on_import_name {
		return reasons, warnings
	}
	if _, on_clause := package_clause_at(document, position); on_clause {
		append(&out, "the position is on the package clause: use rename-package to rename the package")
		return out[:], {}
	}
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
				"`%s` is a package qualifier: use rename-package to rename a package",
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

	if target.flag == .Identifier {
		target.variants = declaration_variants(&target.h, target.symbol)
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
			return "the position is on an import path: rename its alias or a qualifier, or use rename-package to rename the package", true
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
	ast_context: AstContext
	position_context: DocumentPositionContext
	ast_context_at(document, position, &ast_context, &position_context) or_return

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

// The real path of dir with forward slashes. The part of dir that does not exist is joined to the real
// path of its nearest existing ancestor, so a missing dir still compares with an existing root.
canonical_dir :: proc(dir: string) -> string {
	slashed, _ := filepath.replace_separators(dir, '/', context.temp_allocator)
	existing := path.clean(slashed, context.temp_allocator)
	missing := ""
	for {
		if real, err := os.get_absolute_path(existing, context.temp_allocator); err == nil {
			real_slashed, _ := filepath.replace_separators(real, '/', context.temp_allocator)
			return path.join({real_slashed, missing}, context.temp_allocator)
		}
		parent := path.dir(existing, context.temp_allocator)
		if parent == existing {
			return path.join({existing, missing}, context.temp_allocator)
		}
		missing = path.join({path.base(existing), missing}, context.temp_allocator)
		existing = parent
	}
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
		variants, problem := field_variants(&target.h, symbol)
		if problem != "" {
			append(out, problem)
			return
		}
		// The member and the same member of each platform variant of its type, which the rename changes too.
		members_at := make([dynamic]Rename_Site, context.temp_allocator)
		append(&members_at, Rename_Site{document = decl_document, offset = decl_offset})
		for variant in variants {
			document := hierarchy_document(&target.h, variant.uri)
			if document == nil do continue
			offset := common.get_absolute_position(variant.range.start, document.text[:document.used_text]) or_continue
			append(&members_at, Rename_Site{document = document, offset = offset})
		}
		// The type name of each site whose type is a struct; each variant may have embedders of its own.
		type_names := make([dynamic]Rename_Site_Type, context.temp_allocator)
		for site, i in members_at {
			members, owner, site_type_name, found := sibling_members(site.document, site.offset)
			if !found {
				if i == 0 do return
				continue
			}
			for ident in members {
				if ident.name == new_name {
					append(
						out,
						fmt.tprintf(
							"`%s` is already a member of the same type at %s",
							new_name,
							ident_text(site.document, ident),
						),
					)
				}
			}
			struct_type := owner.derived.(^ast.Struct_Type) or_continue
			// Only a struct carries the field on to the types that embed it.
			if site_type_name != nil {
				append(&type_names, Rename_Site_Type{site.document, site_type_name})
			}
			for field in struct_type.fields.list {
				if .Using not_in field.flags || len(field.names) == 0 {
					continue
				}
				via := field.names[0].derived.(^ast.Ident) or_continue
				if slice.contains(using_member_names_of(site.document, field.type), new_name) {
					append(
						out,
						fmt.tprintf(
							"`%s` is already a member of the same type through `using %s` at %s",
							new_name,
							via.name,
							ident_text(site.document, via),
						),
					)
				}
			}
		}
		if len(type_names) > 0 {
			scan := Embed_Scan {
				out         = out,
				new_name    = new_name,
				texts       = workspace_odin_files("", target.h.files),
				types       = make([dynamic]Embed_Type, context.temp_allocator),
				decls       = make([dynamic]Symbol, context.temp_allocator),
				sites       = make([dynamic]^Document, context.temp_allocator),
				resolved    = make(map[^Document]SymbolAndNodeMap, context.temp_allocator),
				when_bodies = make(map[^ast.Block_Stmt]struct{}, context.temp_allocator),
			}
			// Each file is read once here, not once per type that check_embedders searches.
			for &file in scan.texts {
				// package_siblings matches these paths against the forward-slash package_name of a document.
				when ODIN_OS == .Windows {
					file.fullpath, _ = filepath.replace_separators(file.fullpath, '/', context.temp_allocator)
				}
				if file.text == "" {
					data, err := os.read_entire_file(file.fullpath, context.temp_allocator)
					file.text = string(data) if err == nil else ""
				}
			}
			// scan.decls dedupes a type that two sites name.
			for type_name in type_names {
				check_embedders(&scan, target, type_name.document, type_name.ident)
			}
			check_carrier_variants(&scan, target, decl_document.package_name)
			// A `using` of a value whose type the file never names, such as a call result. Odin accepts a `using`
			// statement only in a file with `#+feature using-stmt`, and a `using v := value` declaration anywhere.
			for file in scan.texts {
				if !strings.contains(file.text, "using-stmt") && !declares_using_value(file.text) {
					continue
				}
				uri := common.create_uri(file.fullpath, context.temp_allocator)
				site := hierarchy_document(&target.h, uri.uri)
				if site != nil && !slice.contains(scan.sites[:], site) {
					append(&scan.sites, site)
				}
			}
			check_using_statements(&scan)
		}
	case .Local in symbol.flags:
		for declared in scope_declarations(decl_document, decl_offset) {
			// A member that a `using` parameter brings in clashes with that parameter's own name too.
			if declared.name == new_name && (declared.through_using || declared.ident.pos.offset != decl_offset) {
				append(
					out,
					fmt.tprintf(
						"`%s` is already declared in the same scope%s at %s",
						new_name,
						fmt.tprintf(" through `using %s`", declared.ident.name) if declared.through_using else "",
						ident_text(decl_document, declared.ident),
					),
				)
			}
		}
	case:
		// The files of the declaration and of its variants, each once. The index misses the other targets' files.
		other, found := lookup(new_name, symbol.pkg, decl_document.fullpath)
		scanned := make([dynamic]^Document, context.temp_allocator)
		append(&scanned, decl_document)
		sites := make([dynamic]Rename_Site, context.temp_allocator)
		append(&sites, Rename_Site{decl_document, decl_offset, build_tags(decl_document.ast)})
		next: for variant in target.variants {
			if variant_offset, offset_ok := common.get_absolute_position(
				variant.symbol.range.start,
				variant.document.text[:variant.document.used_text],
			); offset_ok {
				append(&sites, Rename_Site{variant.document, variant_offset, build_tags(variant.document.ast)})
			}
			for scan in scanned {
				if same_path(scan.fullpath, variant.document.fullpath) do continue next
			}
			append(&scanned, variant.document)
		}
		renamed := len(scanned)
		// A sibling that mentions new_name and that some target builds with one of those files, where only its
		// declarations visible to the package count.
		siblings: for sibling in package_siblings(decl_document, target.h.files) {
			slashed, _ := filepath.replace_separators(sibling, '/', context.temp_allocator)
			for scan in scanned[:renamed] {
				if same_path(scan.fullpath, slashed) do continue siblings
			}
			if !file_mentions(&target.h, slashed, new_name) do continue
			document := hierarchy_document(&target.h, common.create_uri(slashed, context.temp_allocator).uri)
			if document == nil || document.ast.pkg_name != decl_document.ast.pkg_name {
				continue
			}
			tags := build_tags(document.ast)
			for site in sites {
				if builds_together(site.document.fullpath, site.tags, document.fullpath, tags) {
					append(&scanned, document)
					break
				}
			}
		}
		for scan, i in scanned {
			for decl in top_level_value_decls(scan.ast) {
				if i >= renamed && file_private(scan, decl) {
					continue
				}
				for name in decl.names {
					if ident, ok := name.derived.(^ast.Ident); ok && ident.name == new_name {
						// A declaration that no target builds together with a renamed one.
						if !builds_with_sites(sites[:], scan, ident.pos.offset) {
							continue
						}
						// The index's declaration is reported here.
						found = found && !strings.equal_fold(other.uri, scan.uri.uri)
						append(
							out,
							fmt.tprintf(
								"`%s` is already declared in the package at %s%s",
								new_name,
								ident_text(scan, ident),
								" (in a when branch)" if in_when(scan.ast, ident.pos.offset) else "",
							),
						)
					}
				}
			}
		}
		// The index holds the files the host builds, which need not build with the renamed declaration.
		if found {
			if home := hierarchy_document(&target.h, other.uri); home != nil {
				if offset, offset_ok := common.get_absolute_position(other.range.start, home.text[:home.used_text]);
				   offset_ok {
					found = builds_with_sites(sites[:], home, offset)
				}
			}
		}
		if found {
			append(out, fmt.tprintf("`%s` is already declared in the package at %s", new_name, declared_at(other)))
		}
	}
}

// The type name of a struct that declares the renamed field, in document.
@(private = "file")
Rename_Site_Type :: struct {
	document: ^Document,
	ident:    ^ast.Ident,
}

// Appends a cause for each declaration in scan.decls of another package than the renamed field, a type or alias
// that carries the field, with a platform variant that does not carry it itself and so keeps the old name.
// field_variants judges the variants in field_pkg, the package that declares the field.
@(private = "file")
check_carrier_variants :: proc(scan: ^Embed_Scan, target: ^Rename_Target, field_pkg: string) {
	// scan.texts holds every workspace text, so the variant search reads no file again. target.h keeps its
	// documents map, which a copy of it could leave stale on growth.
	files := target.h.files
	target.h.files = scan.texts
	defer target.h.files = files
	reported := make([dynamic]Symbol, context.temp_allocator)
	for decl in scan.decls {
		if decl.pkg == field_pkg do continue
		next: for variant in declaration_variants(&target.h, decl) {
			for other in scan.decls {
				if same_symbol(other, variant.symbol) do continue next
			}
			for other in reported {
				if same_symbol(other, variant.symbol) do continue next
			}
			append(&reported, variant.symbol)
			append(
				scan.out,
				fmt.tprintf(
					"`%s` at %s carries the renamed field `%s`, but its platform variant `%s` at %s is another type, which the rename does not change",
					variant.symbol.name,
					declared_at(decl),
					target.old_name,
					variant.symbol.name,
					declared_at(variant.symbol),
				),
			)
		}
	}
}

// A declaration that a rename gives the new name: the renamed one or a variant, at offset in document.
@(private = "file")
Rename_Site :: struct {
	document: ^Document,
	offset:   int,
	tags:     parser.File_Tags, // build_tags of document, when the build check needs them
}

// Whether some target builds document with one of sites, and takes both the `when` branch around offset and the
// one around that site. A site in another arm of a `when` of document than offset never builds with it.
@(private = "file")
builds_with_sites :: proc(sites: []Rename_Site, document: ^Document, offset: int) -> bool {
	tags := build_tags(document.ast)
	for site in sites {
		if same_path(site.document.fullpath, document.fullpath) &&
		   in_other_when_arms(document.ast, site.offset, offset) {
			continue
		}
		if builds_together(
			site.document.fullpath,
			site.tags,
			document.fullpath,
			tags,
			{&site.document.ast, site.offset},
			{&document.ast, offset},
		) {
			return true
		}
	}
	return false
}

// Whether offsets a and b of file lie in different arms of one `when` statement, so that no build takes both.
@(private = "file")
in_other_when_arms :: proc(file: ast.File, a, b: int) -> bool {
	for stmt in file.decls {
		if visit(stmt, a, b) do return true
	}
	return false

	holds :: proc(node: ^ast.Stmt, offset: int) -> bool {
		return node != nil && node.pos.offset <= offset && offset < node.end.offset
	}
	visit :: proc(stmt: ^ast.Stmt, a, b: int) -> bool {
		if !holds(stmt, a) || !holds(stmt, b) do return false
		#partial switch s in stmt.derived {
		case ^ast.When_Stmt:
			for arm in ([2]^ast.Stmt{s.body, s.else_stmt}) {
				if holds(arm, a) != holds(arm, b) do return true
				if holds(arm, a) do return visit(arm, a, b)
			}
		case ^ast.Block_Stmt:
			for inner in s.stmts {
				if visit(inner, a, b) do return true
			}
		case ^ast.Foreign_Block_Decl:
			return visit(s.body, a, b)
		}
		return false
	}
}

// What the check of a field rename learns about the types that carry the field through `using`.
@(private = "file")
Embed_Scan :: struct {
	out:         ^[dynamic]string,
	new_name:    string,
	site:        ^Document, // the document under walk by check_using_statements
	texts:       []Package_File, // every workspace file with its text, read once for the whole scan
	types:       [dynamic]Embed_Type, // the owner type and every type that embeds it, directly or not
	decls:       [dynamic]Symbol, // the declarations searched so far: those types and the aliases of them
	sites:       [dynamic]^Document, // the documents searched for `using` statements and declarations
	resolved:    map[^Document]SymbolAndNodeMap, // the new name resolved in each site
	when_bodies: map[^ast.Block_Stmt]struct{}, // the `when` bodies checked with the statements of their block
}

// A type that carries the renamed field. document, offset and whens anchor an active variant that an inactive
// declaration's name resolves to. The entry then counts only for a `using` outside the other branches of those whens.
@(private = "file")
Embed_Type :: struct {
	symbol:   Symbol,
	document: ^Document,
	offset:   int,
	whens:    []^ast.When_Stmt,
}

// Appends type to scan.types, one entry per anchor. An entry without a document counts for every `using`, so it
// covers any other entry of its symbol and replaces an anchored one.
@(private = "file")
add_embed_type :: proc(scan: ^Embed_Scan, type: Embed_Type) {
	for &seen in scan.types {
		if !same_symbol(seen.symbol, type.symbol) do continue
		if seen.document == nil || (seen.document == type.document && seen.offset == type.offset) do return
		if type.document == nil {
			seen = type
			return
		}
	}
	append(&scan.types, type)
}

// Appends a cause for each struct that embeds the type named type_name through `using`, directly or through
// other structs, and each procedure with a `using` parameter of such a type, where scan.new_name already
// names another member or declaration, or a name in the scope that the field would then capture. Only the
// files of scan.texts that name a type and contain the text `using` anywhere, or declare an alias of it, are
// searched. type_name is the name in the declaration of the type or alias.
@(private = "file")
check_embedders :: proc(scan: ^Embed_Scan, target: ^Rename_Target, document: ^Document, type_name: ^ast.Ident) {
	out, new_name := scan.out, scan.new_name
	at := common.get_token_range(type_name^, document.ast.src)
	// The declaration itself: resolving its name in an inactive `when` branch would yield the active variant.
	type_symbol := Symbol {
		uri   = document.uri.uri,
		range = at,
		pkg   = document.package_name,
		name  = type_name.name,
	}
	// The type itself, as the type of a value resolves, not the identifier that declares it.
	ast_context_value: AstContext
	position_context: DocumentPositionContext
	if !ast_context_at(document, at.start, &ast_context_value, &position_context) {
		return
	}
	value, value_ok := resolve_type_expression(&ast_context_value, type_name)
	if !value_ok {
		return
	}
	// An alias names the same type as its target but has references of its own, so declarations are deduped.
	for seen in scan.decls {
		if same_symbol(seen, type_symbol) {
			return
		}
	}
	append(&scan.decls, type_symbol)
	embed_type := Embed_Type {
		symbol = value,
	}
	// In an inactive `when` branch the name resolves to the active variant, which need not carry the field, and so
	// does a `using` of the name in that branch. The declaration's own type carries the field, and the active
	// variant counts only for a `using` that a target can build together with the declaration.
	if value.name == type_name.name && value.pkg == document.package_name {
		chain := nodes_at(document.ast.decls[:], type_name.pos.offset)
		for node_at in chain {
			decl := node_at.node.derived.(^ast.Value_Decl) or_continue
			if len(decl.names) != 1 || decl.names[0] != type_name || len(decl.values) != 1 {
				continue
			}
			resolved_at := -1
			if value.uri == document.uri.uri {
				resolved_at =
					common.get_absolute_position(value.range.start, document.text[:document.used_text]) or_else -1
			}
			if resolved_at >= decl.pos.offset && resolved_at < decl.end.offset {
				break
			}
			whens := make([dynamic]^ast.When_Stmt, context.temp_allocator)
			for outer in chain {
				if w, ok := outer.node.derived.(^ast.When_Stmt); ok do append(&whens, w)
			}
			embed_type = {value, document, type_name.pos.offset, whens[:]}
			if own, own_ok := resolve_type_expression(&ast_context_value, decl.values[0]); own_ok {
				add_embed_type(scan, {symbol = own})
			}
			break
		}
	}
	add_embed_type(scan, embed_type)
	candidates := make([dynamic]Package_File, context.temp_allocator)
	for file in scan.texts {
		if !strings.contains(file.text, type_name.name) {
			continue
		}
		if strings.contains(file.text, "using") || declares_alias_of(file.text, type_name.name) {
			append(&candidates, file)
		}
	}
	ast_context := globals_context(document)
	// An empty list of files would make the search walk the workspace again.
	locations, _ := find_symbol_references(
		document,
		&ast_context,
		type_symbol,
		.Identifier,
		current_file_only = len(candidates) == 0,
		target_name = type_name.name,
		files = candidates[:],
	)

	for location in locations {
		site := hierarchy_document(&target.h, location.uri)
		if site == nil {
			continue
		}
		if !slice.contains(scan.sites[:], site) {
			append(&scan.sites, site)
		}
		offset := common.get_absolute_position(location.range.start, site.text[:site.used_text]) or_continue
		chain := nodes_at(site.ast.decls[:], offset)
		// `Alias :: Foo`, `distinct Foo` or `^Foo` carries the field to every `using` of the alias.
		for node_at in chain {
			decl := node_at.node.derived.(^ast.Value_Decl) or_continue
			if decl.is_mutable || len(decl.names) != 1 || len(decl.values) != 1 {
				continue
			}
			value := decl.values[0]
			if distinct_type, is_distinct := value.derived.(^ast.Distinct_Type); is_distinct {
				value = distinct_type.type
			}
			used := using_type_ident(value)
			alias, is_ident := decl.names[0].derived.(^ast.Ident)
			if used != nil && used.pos.offset == offset && is_ident {
				check_embedders(scan, target, site, alias)
			}
		}
		for node_at, i in chain {
			field := node_at.node.derived.(^ast.Field) or_continue
			if .Using not_in field.flags || len(field.names) == 0 || i < 2 {
				continue
			}
			used := using_type_ident(field.type)
			if used == nil || used.pos.offset != offset {
				continue
			}
			via := field.names[0].derived.(^ast.Ident) or_continue
			// A field sits in a Field_List of a struct, or of the Proc_Type of a Proc_Lit.
			#partial switch owner in chain[i - 2].node.derived {
			case ^ast.Struct_Type:
				clashes := make([dynamic]^ast.Ident, context.temp_allocator)
				// The embedding field's own name counts; the members it brings in are the old ones.
				for other in owner.fields.list {
					for name in other.names {
						ident := name.derived.(^ast.Ident) or_continue
						if ident.name == new_name {
							append(&clashes, ident)
						}
					}
					if other != field && .Using in other.flags && len(other.names) > 0 {
						other_via := other.names[0].derived.(^ast.Ident) or_continue
						if slice.contains(using_member_names_of(site, other.type), new_name) {
							append(&clashes, other_via)
						}
					}
				}
				for ident in clashes {
					append(
						out,
						fmt.tprintf(
							"`%s` is already a member of a type that embeds this one through `using %s` at %s",
							new_name,
							via.name,
							ident_text(site, ident),
						),
					)
				}
				// The embedding struct carries the field on to the structs that embed it.
				if i >= 3 {
					decl, is_decl := chain[i - 3].node.derived.(^ast.Value_Decl)
					if is_decl && len(decl.names) == 1 {
						if name, is_ident := decl.names[0].derived.(^ast.Ident); is_ident {
							check_embedders(scan, target, site, name)
						}
					}
				}
			case ^ast.Proc_Type:
				if i < 3 {
					continue
				}
				lit := chain[i - 3].node.derived.(^ast.Proc_Lit) or_continue
				names := make([dynamic]Scope_Name, context.temp_allocator)
				append(&names, ..proc_scope(site, lit))
				for nested in nested_declarations({lit.body}) {
					if !slice.contains(names[:], nested) {
						append(&names, nested)
					}
				}
				for declared in names {
					if declared.name == new_name && !(declared.through_using && declared.ident == via) {
						append(
							out,
							fmt.tprintf(
								"`%s` is already declared in the scope of `using %s` at %s",
								new_name,
								via.name,
								ident_text(site, declared.ident),
							),
						)
					}
				}
				if lit.body != nil {
					field_captures(
						scan,
						site,
						via.name,
						{lit.body.pos.offset, lit.body.end.offset},
						{lit.pos.offset, lit.end.offset},
						lit.body.pos.offset,
					)
				}
			}
		}
	}
}

// Whether a line of text has `::`, then optional `distinct`, `^` and package qualifier, then the word name:
// a declaration such as `Alias :: Foo` or `P :: ^pkg.Foo`. A comment or string can match too. A declaration split
// after `::` (`Alias ::` with `Foo` on the next line) is missed; odinfmt joins it.
@(private = "file")
declares_alias_of :: proc(text, name: string) -> bool {
	for at := index_word(text, name, 0); at >= 0; at = index_word(text, name, at + 1) {
		before := text[strings.last_index_byte(text[:at], '\n') + 1:at]
		if strings.has_suffix(before, ".") {
			before = strings.trim_right_proc(before[:len(before) - 1], is_ident_rune)
		}
		before = strings.trim_suffix(strings.trim_right(before, "^ \t"), "distinct")
		if strings.has_suffix(strings.trim_right_space(before), "::") {
			return true
		}
	}
	return false
}

// Whether text has `using`, a name, then `:` and `=` with optional spaces: a declaration such as
// `using v := make_foo()`, whose type the text need not name. A comment or string can match too.
@(private = "file")
declares_using_value :: proc(text: string) -> bool {
	for at := index_word(text, "using", 0); at >= 0; at = index_word(text, "using", at + 1) {
		rest := strings.trim_left(text[at + len("using"):], " \t")
		name := strings.trim_left_proc(rest, is_ident_rune)
		if len(name) == len(rest) {
			continue
		}
		rest = strings.trim_left(name, " \t")
		if !strings.has_prefix(rest, ":") {
			continue
		}
		if strings.has_prefix(strings.trim_left(rest[1:], " \t"), "=") {
			return true
		}
	}
	return false
}

// Appends a cause for each `using` statement or `using` declaration, in the documents of scan, of a value whose
// type carries the renamed field, where new_name is declared in its scope or used there for something else.
@(private = "file")
check_using_statements :: proc(scan: ^Embed_Scan) {
	for site in scan.sites {
		scan.site = site
		visitor := ast.Visitor {
			data  = scan,
			visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
				if node == nil do return nil
				scan := (^Embed_Scan)(visitor.data)
				#partial switch n in node.derived {
				case ^ast.Block_Stmt:
					// A `when` body inside a block was checked with the statements of that block.
					if n not_in scan.when_bodies {
						check_using_in_block(scan, n.stmts, {n.pos.offset, n.end.offset})
					}
				case ^ast.Case_Clause:
					check_using_in_block(scan, n.body, {n.pos.offset, n.end.offset})
				}
				return visitor
			},
		}
		for decl in site.ast.decls {
			ast.walk(&visitor, decl)
		}
	}
}

// The `using` statements and `using` declarations among stmts, the statements of a block that spans the
// offsets of block. A `when` body opens no scope, so its statements join those of the block in text order.
@(private = "file")
check_using_in_block :: proc(scan: ^Embed_Scan, block_stmts: []^ast.Stmt, block: [2]int) {
	stmts := make([dynamic]^ast.Stmt, context.temp_allocator)
	whens := make([dynamic]^ast.When_Stmt, context.temp_allocator)
	flatten_when_bodies(scan, &stmts, &whens, block_stmts)
	for stmt, i in stmts {
		if stmt == nil do continue
		#partial switch s in stmt.derived {
		case ^ast.Using_Stmt:
			for expr in s.list {
				via, _ := expr.derived.(^ast.Ident)
				text := scan.site.ast.src[expr.pos.offset:expr.end.offset]
				check_using_value(scan, stmts[:], whens[:], i, expr, text, via, block)
			}
		case ^ast.Value_Decl:
			// `using v: T` brings in the fields of T, and `using v := value` those of the value's type.
			if !s.is_using || len(s.names) == 0 do continue
			via := s.names[0].derived.(^ast.Ident) or_continue
			expr := strip_parens_and_pointers(s.type) if s.type != nil else (s.values[0] if len(s.values) > 0 else nil)
			check_using_value(scan, stmts[:], whens[:], i, expr, via.name, via, block)
		}
	}
}

// Appends stmts to flat with the statements of each `when` branch in place of the `when`, records each branch
// body in scan.when_bodies and each `when` in whens. The else of a `when` is a block or another `when`.
@(private = "file")
flatten_when_bodies :: proc(
	scan: ^Embed_Scan,
	flat: ^[dynamic]^ast.Stmt,
	whens: ^[dynamic]^ast.When_Stmt,
	stmts: []^ast.Stmt,
) {
	for stmt in stmts {
		when_stmt: ^ast.When_Stmt
		if stmt != nil {
			when_stmt, _ = stmt.derived.(^ast.When_Stmt)
		}
		if when_stmt == nil {
			append(flat, stmt)
			continue
		}
		append(whens, when_stmt)
		for branch in ([]^ast.Stmt{when_stmt.body, when_stmt.else_stmt}) {
			if branch == nil {
				continue
			}
			if body, is_block := branch.derived.(^ast.Block_Stmt); is_block {
				scan.when_bodies[body] = {}
				flatten_when_bodies(scan, flat, whens, body.stmts)
			} else {
				flatten_when_bodies(scan, flat, whens, {branch})
			}
		}
	}
}

// Whether offsets a and b lie in different branches of one of whens. No target builds both branches of a `when`.
@(private = "file")
in_other_branch :: proc(whens: []^ast.When_Stmt, a, b: int) -> bool {
	inside :: proc(stmt: ^ast.Stmt, offset: int) -> bool {
		return stmt != nil && stmt.pos.offset <= offset && offset < stmt.end.offset
	}
	for w in whens {
		if (inside(w.body, a) && inside(w.else_stmt, b)) || (inside(w.body, b) && inside(w.else_stmt, a)) {
			return true
		}
	}
	return false
}

// Appends the causes for stmts[i], a `using` of expr, spelled text, in a block that spans the offsets of block,
// when the type of expr carries the renamed field. via is the name that the `using` declares or names, or nil.
// whens are the `when` statements whose branches stmts holds; a name in another branch than the `using` is apart.
@(private = "file")
check_using_value :: proc(
	scan: ^Embed_Scan,
	stmts: []^ast.Stmt,
	whens: []^ast.When_Stmt,
	i: int,
	expr: ^ast.Expr,
	text: string,
	via: ^ast.Ident,
	block: [2]int,
) {
	if expr == nil || !carries_field(scan, expr) {
		return
	}
	// The names of the block, those of the blocks after the statement, and the members of the later `using`s
	// of the block, which collide with the field as the earlier ones do.
	names := make([dynamic]Scope_Name, context.temp_allocator)
	collect_stmts(&names, scan.site, stmts[:i + 1])
	append(&names, ..nested_declarations(stmts[i + 1:]))
	later := make([dynamic]Scope_Name, context.temp_allocator)
	collect_stmts(&later, scan.site, stmts[i + 1:])
	for name in later {
		if name.through_using do append(&names, name)
	}
	using_at := stmts[i].pos.offset
	for declared in names {
		if in_other_branch(whens, using_at, declared.ident.pos.offset) do continue
		// The members that this `using` brings in are the old ones, which the member check covers.
		if declared.name == scan.new_name && !(declared.through_using && declared.ident == via) {
			append(
				scan.out,
				fmt.tprintf(
					"`%s` is already declared in the scope of `using %s` at %s",
					scan.new_name,
					text,
					ident_text(scan.site, declared.ident),
				),
			)
		}
	}
	field_captures(scan, scan.site, text, {stmts[i].end.offset, block[1]}, block, block[0], whens, using_at)
}

// Whether the value of expr has a type that carries the renamed field.
@(private = "file")
carries_field :: proc(scan: ^Embed_Scan, expr: ^ast.Expr) -> bool {
	ast_context: AstContext
	position_context: DocumentPositionContext
	at := common.get_token_range(expr^, scan.site.ast.src).start
	ast_context_at(scan.site, at, &ast_context, &position_context) or_return
	// A call resolves to its procedure, and `using` reads the type of its first result, as get_locals_using does.
	symbol, _ := unwrap_procedure_until_struct_bit_field_or_package(&ast_context, expr) or_return
	// A type resolved from a call result is the declaration, which spans the type's name, not its body.
	for type in scan.types {
		if !same_symbol(type.symbol, symbol) do continue
		if type.document != scan.site || !in_other_branch(type.whens, type.offset, expr.pos.offset) {
			return true
		}
	}
	for decl in scan.decls {
		if same_symbol(decl, symbol) {
			return true
		}
	}
	return false
}

// Appends a cause for each use of new_name in the offsets of uses that means a declaration outside the
// offsets of scope, since the field that `using via` brings in would capture it after the rename. block is
// the offset of the block whose scope `using via` enters; a procedure's parameters share its body's scope. A use
// in another branch of one of whens than the `using` at offset using_at is skipped.
@(private = "file")
field_captures :: proc(
	scan: ^Embed_Scan,
	site: ^Document,
	via: string,
	uses, scope: [2]int,
	block: int,
	whens: []^ast.When_Stmt = {},
	using_at := 0,
) {
	out, new_name := scan.out, scan.new_name
	hits, cached := scan.resolved[site]
	if !cached {
		hits = resolve_entire_file_for_references(site, context.temp_allocator, .Identifier, new_name)
		scan.resolved[site] = hits
	}
	text := site.text[:site.used_text]
	for key, hit in hits {
		// A selector field, composite-literal key or named argument is keyed by its parent node.
		if key != uintptr(hit.node) {
			continue
		}
		ident := hit.node.derived.(^ast.Ident) or_continue
		if ident.name != new_name || ident.pos.offset < uses[0] || ident.pos.offset >= uses[1] {
			continue
		}
		if in_other_branch(whens, using_at, ident.pos.offset) {
			continue
		}
		// A procedure literal inside the scope cannot see the `using` value.
		nested := false
		for chain_at in nodes_at(site.ast.decls[:], ident.pos.offset) {
			lit, is_lit := chain_at.node.derived.(^ast.Proc_Lit)
			nested ||= is_lit && lit.pos.offset >= uses[0]
		}
		if nested {
			continue
		}
		other := hit.symbol^
		at := common.get_token_range(ident^, site.ast.src)
		if other.range == at && strings.equal_fold(other.uri, site.uri.uri) {
			continue
		}
		// Odin resolves a field that a `using` of a nested block brings in before the renamed field. A field
		// from a `using` of the same scope or an outer one is captured.
		if other.type == .Field {
			if range, is_using := using_range_at(site, at.start, ident.pos.offset, new_name); is_using {
				start, ok := common.get_absolute_position(range.start, text)
				if ok && in_nested_block(site, start, block) {
					continue
				}
			}
		}
		// A declaration inside the scope shadows the field, which the collision check reports.
		if strings.equal_fold(other.uri, site.uri.uri) {
			start, ok := common.get_absolute_position(other.range.start, text)
			if ok && scope[0] <= start && start < scope[1] {
				continue
			}
		}
		append(
			out,
			fmt.tprintf(
				"at %s `%s` refers to %s, but after the rename it would mean the field through `using %s`",
				location_text(common.Location{uri = site.uri.uri, range = at}, site),
				new_name,
				describe(other, new_name),
				via,
			),
		)
	}
}

// Whether offset lies in a block or case clause nested inside the block that starts at block. A `when`
// body is no scope of its own.
@(private = "file")
in_nested_block :: proc(document: ^Document, offset, block: int) -> bool {
	for at in nodes_at(document.ast.decls[:], offset) {
		if at.node.pos.offset <= block {
			continue
		}
		#partial switch _ in at.node.derived {
		case ^ast.Block_Stmt:
			if at.parent != nil {
				if _, in_when := at.parent.derived.(^ast.When_Stmt); in_when {
					continue
				}
			}
			return true
		case ^ast.Case_Clause:
			return true
		}
	}
	return false
}

// The names that stmts declare at any depth: declarations, loop values and type switch variables, but
// not the names inside a procedure literal, which has a scope of its own.
@(private = "file")
nested_declarations :: proc(stmts: []^ast.Stmt) -> []Scope_Name {
	names := make([dynamic]Scope_Name, context.temp_allocator)
	visitor := ast.Visitor {
		data  = &names,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			names := (^[dynamic]Scope_Name)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Value_Decl:
				collect_exprs(names, n.names)
			case ^ast.Range_Stmt:
				collect_exprs(names, n.vals)
			case ^ast.Type_Switch_Stmt:
				collect_switch_variable(names, n)
			}
			return visitor
		},
	}
	for stmt in stmts {
		if stmt != nil {
			ast.walk(&visitor, stmt)
		}
	}
	return names[:]
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

	ast_context := globals_context(document)
	variants := variant_symbols(target.variants)
	locations, _ := find_symbol_references(
		document,
		&ast_context,
		symbol,
		.Identifier,
		target_name = target.old_name,
		files = files,
		variants = variants,
	)

	// A reference that new_name would resolve elsewhere. A declaration, of the target or a variant, is none.
	for location in locations {
		if _, declaration := reference_target({uri = location.uri, range = location.range}, symbol, variants);
		   declaration {
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
			// A later local is the inner one, and get_local prefers it. A name from `using` counts as a local
			// declared at its `using`.
			other_range, other_local := other.range, .Local in other.flags
			using_range, is_using := common.Range{}, false
			if other.type == .Field {
				using_range, is_using = using_range_at(site, location.range.start, offset, new_name)
			}
			if is_using {
				other_range, other_local = using_range, true
			}
			captured = other_local && range_after(other_range, symbol.range)
		} else {
			// A global of the same package is a collision, already reported, unless it is private to another
			// file: Odin accepts that declaration, but it captures the references in its file.
			// A field that `using` brings into scope captures like a local.
			captured =
				.Local in other.flags ||
				other.type == .Field ||
				other.type == .Package ||
				other.pkg != symbol.pkg ||
				(!strings.equal_fold(other.uri, symbol.uri) &&
						strings.equal_fold(other.uri, location.uri) &&
						file_private_global(site, new_name))
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
		at := common.get_token_range(ident^, document.ast.src)
		other_range, other_local := other.range, .Local in other.flags
		using_range, is_using := common.Range{}, false
		if other.type == .Field {
			using_range, is_using = using_range_at(document, at.start, ident.pos.offset, new_name)
		}
		if is_using {
			other_range, other_local = using_range, true
		}
		if other_local && !range_after(symbol.range, other_range) {
			continue
		}
		// A declaration, such as a member of a procedure-local type keyed by its own name, is no use.
		if other.range == at && strings.equal_fold(other.uri, document.uri.uri) {
			continue
		}
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

// Whether document declares name at file scope as `@(private="file")` or under `#+private file`.
@(private = "file")
file_private_global :: proc(document: ^Document, name: string) -> bool {
	for global in collect_globals(document.ast, open_file = true) {
		if global.name == name && global.private == .File {
			return true
		}
	}
	return false
}

// The range of the `using` expression that brings name into scope at position, when one does.
@(private = "file")
using_range_at :: proc(
	document: ^Document,
	position: common.Position,
	offset: int,
	name: string,
) -> (
	range: common.Range,
	ok: bool,
) {
	ast_context: AstContext
	position_context: DocumentPositionContext
	ast_context_at(document, position, &ast_context, &position_context) or_return

	ident: ast.Ident
	ident.name = name
	ident.pos = {
		file   = document.ast.fullpath,
		offset = offset,
	}
	local := get_local(ast_context, ident) or_return
	is_using_local(local) or_return
	return common.get_token_range(local.lhs, document.ast.src), true
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
	ast_context: AstContext
	position_context: DocumentPositionContext
	ast_context_at(document, position, &ast_context, &position_context) or_return

	ident: ast.Ident
	ident.name = name
	ident.pos = {
		file   = document.ast.fullpath,
		offset = offset,
	}
	return resolve_location_identifier(&ast_context, ident)
}

// The resolution environment of document with its globals and no locals.
@(private = "package")
globals_context :: proc(document: ^Document) -> AstContext {
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
	return ast_context
}

// The resolution environment at position in document, with the globals and the locals visible there.
@(private = "package")
ast_context_at :: proc(
	document: ^Document,
	position: common.Position,
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
) -> bool {
	ast_context^ = globals_context(document)
	position_context^ = get_document_position_context(document, position, .Hover) or_return
	ast_context.position_hint = position_context.hint
	get_locals(ast_context, position_context)
	return true
}

// expr without its parentheses and pointer types, as expand_usings reads the type of a `using` field.
@(private = "package")
strip_parens_and_pointers :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	if expr == nil {
		return nil
	}
	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		return strip_parens_and_pointers(e.expr)
	case ^ast.Pointer_Type:
		return strip_parens_and_pointers(e.elem)
	}
	return expr
}

// The identifier that names the type of a `using` field: `T`, `^T`, `(T)` or `pkg.T`.
@(private = "file")
using_type_ident :: proc(type_expr: ^ast.Expr) -> ^ast.Ident {
	expr := strip_parens_and_pointers(type_expr)
	if expr == nil {
		return nil
	}
	#partial switch e in expr.derived {
	case ^ast.Ident:
		return e
	case ^ast.Selector_Expr:
		return e.field
	}
	return nil
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

// The members of the struct, enum or bit_field type that declares the member named at offset, that type,
// and the name it is declared with, nil for an anonymous type.
@(private = "file")
sibling_members :: proc(
	document: ^Document,
	offset: int,
) -> (
	members: []^ast.Ident,
	owner: ^ast.Node,
	type_name: ^ast.Ident,
	found: bool,
) {
	for at in nodes_at(document.ast.decls[:], offset) {
		list: []^ast.Ident
		#partial switch n in at.node.derived {
		case ^ast.Value_Decl:
			type_name = nil
			if len(n.names) == 1 {
				type_name, _ = n.names[0].derived.(^ast.Ident)
			}
			continue
		case ^ast.Distinct_Type:
			continue
		case ^ast.Struct_Type:
			list, _ = type_members(n)
		case ^ast.Enum_Type:
			list, _ = type_members(n)
		case ^ast.Bit_Field_Type:
			list, _ = type_members(n)
		}
		for ident in list {
			if ident.pos.offset == offset {
				return list, at.node, type_name, true
			}
		}
		// Only the value of the declaration itself is named by it.
		type_name = nil
	}
	return {}, nil, nil, false
}

// A name declared in a scope. ident is its declaration, or the `using` parameter that brings it into
// scope when through_using is set.
@(private = "file")
Scope_Name :: struct {
	name:          string,
	ident:         ^ast.Ident,
	through_using: bool,
}

// The names declared directly in the innermost scope around offset: a block with the parameters of its
// procedure, a procedure's parameters and body, a case clause, a type switch, or a statement's loop
// values and init declaration. A `when` body is no scope of its own.
@(private = "file")
scope_declarations :: proc(document: ^Document, offset: int) -> []Scope_Name {
	names := make([dynamic]Scope_Name, context.temp_allocator)
	chain := nodes_at(document.ast.decls[:], offset)
	#reverse for at, i in chain {
		#partial switch n in at.node.derived {
		case ^ast.Block_Stmt:
			if at.parent != nil {
				if _, in_when := at.parent.derived.(^ast.When_Stmt); in_when {
					continue
				}
				if lit, is_lit := at.parent.derived.(^ast.Proc_Lit); is_lit && lit.body == n {
					return proc_scope(document, lit)
				}
			}
			collect_stmts(&names, document, n.stmts)
			return names[:]
		case ^ast.Proc_Lit:
			return proc_scope(document, n)
		case ^ast.Case_Clause:
			collect_stmts(&names, document, n.body)
			// The variable of a type switch is declared in each clause: switch, its body, the clause.
			if i >= 2 {
				if switch_stmt, is_type_switch := chain[i - 2].node.derived.(^ast.Type_Switch_Stmt); is_type_switch {
					collect_switch_variable(&names, switch_stmt)
				}
			}
			return names[:]
		case ^ast.Type_Switch_Stmt:
			collect_switch_variable(&names, n)
			if n.body != nil {
				if body, is_block := n.body.derived.(^ast.Block_Stmt); is_block {
					for stmt in body.stmts {
						if clause, is_clause := stmt.derived.(^ast.Case_Clause); is_clause {
							collect_stmts(&names, document, clause.body)
						}
					}
				}
			}
			return names[:]
		case ^ast.Range_Stmt:
			collect_exprs(&names, n.vals)
			return names[:]
		case ^ast.For_Stmt:
			collect_stmts(&names, document, {n.init})
			return names[:]
		case ^ast.If_Stmt:
			collect_stmts(&names, document, {n.init})
			return names[:]
		case ^ast.Switch_Stmt:
			collect_stmts(&names, document, {n.init})
			return names[:]
		}
	}
	return names[:]
}

// The variable of a type switch, which each clause declares.
@(private = "file")
collect_switch_variable :: proc(names: ^[dynamic]Scope_Name, switch_stmt: ^ast.Type_Switch_Stmt) {
	if switch_stmt.tag == nil {
		return
	}
	if tag, is_assign := switch_stmt.tag.derived.(^ast.Assign_Stmt); is_assign {
		collect_exprs(names, tag.lhs)
	}
}

// The parameters, results and top-level body declarations of lit, with the members that its `using`
// parameters bring into scope.
@(private = "file")
proc_scope :: proc(document: ^Document, lit: ^ast.Proc_Lit) -> []Scope_Name {
	names := make([dynamic]Scope_Name, context.temp_allocator)
	if lit.type != nil {
		for list in ([]^ast.Field_List{lit.type.params, lit.type.results}) {
			if list == nil {
				continue
			}
			for field in list.list {
				collect_exprs(&names, field.names)
				if .Using not_in field.flags || len(field.names) == 0 {
					continue
				}
				via := field.names[0].derived.(^ast.Ident) or_continue
				for member in using_member_names_of(document, field.type) {
					append(&names, Scope_Name{member, via, true})
				}
			}
		}
	}
	if lit.body != nil {
		if body, is_block := lit.body.derived.(^ast.Block_Stmt); is_block {
			collect_stmts(&names, document, body.stmts)
		}
	}
	return names[:]
}

// The names that stmts of document declare, with those in their `when` bodies and the members that a
// `using` declaration or a `using` statement of a name brings into scope.
@(private = "file")
collect_stmts :: proc(names: ^[dynamic]Scope_Name, document: ^Document, stmts: []^ast.Stmt) {
	for stmt in stmts {
		if stmt == nil {
			continue
		}
		#partial switch s in stmt.derived {
		case ^ast.Value_Decl:
			collect_exprs(names, s.names)
			if !s.is_using || len(s.names) == 0 do continue
			via := s.names[0].derived.(^ast.Ident) or_continue
			// The members come from the type, or else from the value.
			expr := s.type if s.type != nil else (s.values[0] if len(s.values) > 0 else nil)
			for member in using_member_names_of(document, expr) {
				append(names, Scope_Name{member, via, true})
			}
		case ^ast.Using_Stmt:
			for expr in s.list {
				via := expr.derived.(^ast.Ident) or_continue
				for member in using_member_names_of(document, expr) {
					append(names, Scope_Name{member, via, true})
				}
			}
		case ^ast.When_Stmt:
			// The else of a `when` is a block or another `when`.
			for branch in ([]^ast.Stmt{s.body, s.else_stmt}) {
				if branch == nil {
					continue
				}
				if block, is_block := branch.derived.(^ast.Block_Stmt); is_block {
					collect_stmts(names, document, block.stmts)
				} else {
					collect_stmts(names, document, {branch})
				}
			}
		}
	}
}

@(private = "file")
collect_exprs :: proc(names: ^[dynamic]Scope_Name, exprs: []^ast.Expr) {
	for expr in exprs {
		if ident, ok := expr.derived.(^ast.Ident); ok {
			append(names, Scope_Name{ident.name, ident, false})
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
