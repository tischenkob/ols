#+private file
package server

import "core:fmt"
import "core:odin/ast"
import path "core:path/slashpath"

import "src:common"

/*
	Selector completion on the name of a package that the file doesn't import, like `mem.`.
	The members of that package are offered and every item carries the import as an additional edit,
	the same import that `append_non_imported_packages` adds for the bare package name.
*/

Unimported_Package :: struct {
	collection: string,
	pkg:        string, // relative to the collection, like `mem` or `mem/virtual`
	fullpath:   string,
}

// The package that `name` refers to when no import provides it. Ties go to `core`, then the shortest path.
find_unimported_package :: proc(
	ast_context: ^AstContext,
	name: string,
	config: ^common.Config,
) -> (
	best: Unimported_Package,
	ok: bool,
) {
	candidates: for collection, pkgs in build_cache.pkg_aliases {
		for pkg in pkgs {
			if path.base(pkg) != name {
				continue
			}

			fullpath := path.join({config.collections[collection], pkg}, context.temp_allocator)
			if fullpath == ast_context.document_package {
				continue
			}

			for imp in ast_context.imports {
				if imp.base == name {
					return {}, false
				}
				if imp.name == fullpath {
					continue candidates
				}
			}

			candidate := Unimported_Package{collection, pkg, fullpath}
			if !ok || better_candidate(candidate, best) {
				best = candidate
				ok = true
			}
		}
	}

	return
}

better_candidate :: proc(a, b: Unimported_Package) -> bool {
	if (a.collection == "core") != (b.collection == "core") {
		return a.collection == "core"
	}
	if len(a.pkg) != len(b.pkg) {
		return len(a.pkg) < len(b.pkg)
	}
	if a.collection != b.collection {
		return a.collection < b.collection
	}
	return a.pkg < b.pkg
}

// Placed like the edit of `append_non_imported_packages`.
import_edit :: proc(ast_context: ^AstContext, found: Unimported_Package, config: ^common.Config) -> TextEdit {
	line := ast_context.file.pkg_decl.end.line + 1
	text := fmt.tprintf("import \"%v:%v\"\n", found.collection, found.pkg)
	if config.enable_add_import_to_bottom {
		is_import: bool
		line, is_import = find_most_bottom_line_number(ast_context)
		if !is_import {
			text = fmt.tprintf("\nimport \"%v:%v\"", found.collection, found.pkg)
		}
	}
	return TextEdit{range = {start = {line = line}, end = {line = line}}, newText = text}
}

// The package a selector names when its left side is an identifier that nothing resolves. Records the import in
// `ast_context.auto_import_edit`.
@(private = "package")
rols_unimported_package_symbol :: proc(
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	config: ^common.Config,
) -> (
	symbol: Symbol,
	ok: bool,
) {
	if !config.enable_auto_import {
		return {}, false
	}

	ident := position_context.selector.derived.(^ast.Ident) or_return
	// A declared name whose type doesn't resolve still shadows the package.
	if _, is_local := get_local(ast_context^, ident^); is_local || ident.name in ast_context.globals {
		return {}, false
	}
	found := find_unimported_package(ast_context, ident.name, config) or_return

	try_build_package(found.fullpath)
	ast_context.auto_import_edit = import_edit(ast_context, found, config)

	return Symbol{type = .Package, pkg = found.fullpath, value = SymbolPackageValue{}}, true
}

@(private = "package")
rols_append_auto_import_edit :: proc(ast_context: ^AstContext, items: []CompletionItem) {
	edit, ok := ast_context.auto_import_edit.?
	if !ok {
		return
	}

	for &item in items {
		existing := item.additionalTextEdits.? or_else nil
		edits := make([]TextEdit, len(existing) + 1, context.temp_allocator)
		copy(edits, existing)
		edits[len(edits) - 1] = edit
		item.additionalTextEdits = edits
	}
}
