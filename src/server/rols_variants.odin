package server

import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:common"

// A platform variant of a package-level declaration: a declaration of the same name in the same package
// that a build condition can keep apart from it. Renaming or reshaping one variant must change all of
// them, or the targets that build another variant break.
Decl_Variant :: struct {
	document: ^Document,
	decl:     ^ast.Value_Decl,
	symbol:   Symbol, // uri, name range, package and name, as a reference to it resolves
}

// The variants of the package-level declaration that symbol names, without the declaration itself.
//
// A candidate is a value declaration at file scope, under `when` statements and foreign blocks included,
// with the same name, in an .odin file of the same directory with the same `package` clause. A file with
// `#+build ignore` builds nowhere and is left out. The candidate is a variant unless both declarations
// are always built together, which odin rejects as a redeclaration:
// - both sit outside any `when` in files that the current target builds, or
// - both sit in the same `when` branch of one file, or both outside any `when` of one file.
// A file-private declaration (`@(private="file")` or `#+private file`) only has variants in its own file, and
// a declaration in another file is never a variant of one: each file may declare its own.
// Any other pair has a build condition that can tell them apart: a file name suffix or `#+build` line,
// or a `when` condition, which this does not evaluate.
declaration_variants :: proc(h: ^Call_Hierarchy, symbol: Symbol) -> []Decl_Variant {
	if .Local in symbol.flags || symbol.uri == "" {
		return {}
	}
	home := hierarchy_document(h, symbol.uri)
	if home == nil {
		return {}
	}
	home_src := string(home.text[:home.used_text])
	target: ^ast.Ident
	target_private: bool
	for decl in top_level_value_decls(home.ast) {
		for expr in decl.names {
			ident := expr.derived.(^ast.Ident) or_continue
			if common.get_token_range(ident^, home_src) == symbol.range {
				target, target_private = ident, file_private(home, decl)
			}
		}
	}
	if target == nil {
		return {}
	}
	target_branch := when_branch_of(home.ast, target.pos.offset)
	target_always := target_branch == nil && builds_on_host(home)

	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, home.fullpath)
	if !target_private {
		for sibling in package_siblings(home, h.files) {
			slashed, _ := filepath.replace_separators(sibling, '/', context.temp_allocator)
			// Most siblings never mention the name, so they are not parsed.
			if mentions(h, slashed, target.name) do append(&paths, slashed)
		}
	}

	variants := make([dynamic]Decl_Variant, context.temp_allocator)
	for fullpath in paths {
		document := hierarchy_document(h, common.create_uri(fullpath, context.temp_allocator).uri)
		if document == nil || document.ast.pkg_name != home.ast.pkg_name {
			continue
		}
		if parser.parse_file_tags(document.ast, context.temp_allocator).ignore {
			continue
		}
		same_file := document.fullpath == home.fullpath
		always := builds_on_host(document)
		src := string(document.text[:document.used_text])
		for decl in top_level_value_decls(document.ast) {
			for expr in decl.names {
				ident := expr.derived.(^ast.Ident) or_continue
				if ident.name != target.name || (same_file && ident.pos.offset == target.pos.offset) {
					continue
				}
				branch := when_branch_of(document.ast, ident.pos.offset)
				if (target_always && always && branch == nil) ||
				   (same_file && branch == target_branch) ||
				   (!same_file && file_private(document, decl)) {
					continue
				}
				variant_symbol := symbol
				variant_symbol.name = ident.name
				variant_symbol.uri = document.uri.uri
				variant_symbol.range = common.get_token_range(ident^, src)
				append(&variants, Decl_Variant{document, decl, variant_symbol})
			}
		}
	}
	return variants[:]
}

// The locations a rename at the position changes: the references of the symbol there and, for a package-level
// declaration, of its variants, with the declared name of each variant.
rename_locations :: proc(
	document: ^Document,
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	files: []Package_File,
) -> (
	[]common.Location,
	bool,
) {
	symbol, flag, ok := prepare_references(document, ast_context, position_context)
	if !ok {
		return {}, true
	}
	variants: []Symbol
	if flag == .Identifier {
		h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}
		h.documents[document.uri.uri] = document
		variants = variant_symbols(declaration_variants(&h, symbol))
	}
	return find_symbol_references(
		document,
		ast_context,
		symbol,
		flag,
		target_name = get_target_name(position_context, flag),
		files = files,
		variants = variants,
	)
}

// The symbols of variants, for find_symbol_references.
variant_symbols :: proc(variants: []Decl_Variant) -> []Symbol {
	symbols := make([]Symbol, len(variants), context.temp_allocator)
	for variant, i in variants {
		symbols[i] = variant.symbol
	}
	return symbols
}

// The declaration a resolved reference names, when it is symbol or one of variants.
reference_target :: proc(resolved: Symbol, symbol: Symbol, variants: []Symbol) -> (Symbol, bool) {
	if strings.equal_fold(resolved.uri, symbol.uri) && resolved.range == symbol.range {
		return symbol, true
	}
	for variant in variants {
		if strings.equal_fold(resolved.uri, variant.uri) && resolved.range == variant.range {
			return variant, true
		}
	}
	return {}, false
}

// Adds the declared name of each variant that is not there yet, since the resolver does not reach it in an
// inactive `when` branch.
add_variant_declarations :: proc(locations: ^[dynamic]common.Location, variants: []Symbol) {
	next: for variant in variants {
		for location in locations {
			if strings.equal_fold(location.uri, variant.uri) && location.range == variant.range do continue next
		}
		append(locations, common.Location{uri = variant.uri, range = variant.range})
	}
}

// The `when` branch block that holds offset most closely in file, nil outside any `when`.
@(private = "file")
when_branch_of :: proc(file: ast.File, offset: int) -> ^ast.Stmt {
	innermost: ^ast.Stmt
	for stmt in file.decls do visit(stmt, offset, &innermost)
	return innermost

	visit :: proc(stmt: ^ast.Stmt, offset: int, innermost: ^^ast.Stmt) {
		if stmt == nil || offset < stmt.pos.offset || offset >= stmt.end.offset do return
		#partial switch s in stmt.derived {
		case ^ast.When_Stmt:
			for branch in ([2]^ast.Stmt{s.body, s.else_stmt}) {
				if branch == nil || offset < branch.pos.offset || offset >= branch.end.offset do continue
				if _, is_block := branch.derived.(^ast.Block_Stmt); is_block do innermost^ = branch
				visit(branch, offset, innermost)
			}
		case ^ast.Block_Stmt:
			for inner in s.stmts do visit(inner, offset, innermost)
		case ^ast.Foreign_Block_Decl:
			visit(s.body, offset, innermost)
		}
	}
}

// Whether the target that the index builds for, the host or the profile, builds document.
@(private = "file")
builds_on_host :: proc(document: ^Document) -> bool {
	return builds_on(document.fullpath, string(document.text[:document.used_text]), host_target())
}

// Whether the text of the file at fullpath, as hierarchy_document reads it, contains name.
@(private = "file")
mentions :: proc(h: ^Call_Hierarchy, fullpath, name: string) -> bool {
	if open := &document_storage.documents[fullpath]; open != nil && open.client_owned {
		return strings.contains(string(open.text[:open.used_text]), name)
	}
	for file in h.files {
		if file.fullpath == fullpath do return strings.contains(file.text, name)
	}
	data, err := os.read_entire_file(fullpath, context.temp_allocator)
	return err == nil && strings.contains(string(data), name)
}

// Whether decl of document is private to its file, by its attribute or by `#+private file`.
@(private = "file")
file_private :: proc(document: ^Document, decl: ^ast.Value_Decl) -> bool {
	tags := parser.parse_file_tags(document.ast, context.temp_allocator)
	return is_file_private(decl.attributes[:]) || tags.private == .File
}
