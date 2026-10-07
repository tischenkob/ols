package server

import "core:fmt"
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
			if file_mentions(h, slashed, target.name) do append(&paths, slashed)
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

// The variants of decl, a top-level declaration of document, read through h, which then holds document.
top_level_variants :: proc(h: ^Call_Hierarchy, document: ^Document, decl: ^ast.Value_Decl) -> []Decl_Variant {
	h.documents[document.uri.uri] = document
	symbol := Symbol {
		uri   = document.uri.uri,
		range = common.get_token_range(decl.names[0], document.ast.src),
		pkg   = document.package_name,
		name  = final_name(decl.names[0]),
	}
	return declaration_variants(h, symbol)
}

// The members named like the member that symbol names in the platform variants of its type, as references to them
// resolve. The member must belong directly to the struct, enum or bit_field type of a package-level declaration,
// else there are none. The types that reach the member are that type and the package-level declarations that alias
// it or embed it with `using`, directly or through another of them, so their variants count too. A variant without
// such a member is left out. problem names a variant whose member the rename cannot reach, "" when there is none: a
// variant that is no struct, enum or bit_field type, such as an alias `S :: S_Windows`, or a struct without the
// member that may reach it through a `using` field. An alias or `using` of a type that reaches the member is no
// problem. fields then holds the members found.
field_variants :: proc(h: ^Call_Hierarchy, symbol: Symbol) -> (fields: []Symbol, problem: string) {
	home := hierarchy_document(h, symbol.uri)
	if home == nil {
		return
	}
	home_src := string(home.text[:home.used_text])
	for decl in top_level_value_decls(home.ast) {
		for value, i in decl.values {
			if i >= len(decl.names) do break
			members := type_members(value) or_continue
			for member in members {
				if common.get_token_range(member^, home_src) != symbol.range do continue
				types := make([dynamic]Decl_Variant, context.temp_allocator)
				covered := make(map[string]struct{}, context.temp_allocator)
				owner := Symbol {
					uri   = home.uri.uri,
					range = common.get_token_range(decl.names[i], home_src),
					pkg   = home.package_name,
					name  = final_name(decl.names[i]),
				}
				append(&types, Decl_Variant{home, decl, owner})
				covered[owner.name] = {}
				// types grows while it is walked, so aliases of aliases are found too.
				for k := 0; k < len(types); k += 1 {
					for user in type_users(h, types[k]) {
						if user.symbol.name in covered do continue
						covered[user.symbol.name] = {}
						append(&types, user)
					}
				}
				found := make([dynamic]Symbol, context.temp_allocator)
				for reaching in types {
					for variant in declaration_variants(h, reaching.symbol) {
						add_member_variant(
							variant,
							reaching.symbol.name,
							member.name,
							symbol,
							covered,
							&found,
							&problem,
						)
					}
				}
				return found[:], problem
			}
		}
	}
	return
}

// Adds the member named member_name of variant, a platform variant of the type named type_name, to found, unless
// found holds it. Sets problem when the rename cannot reach the member there. covered holds the names of the types
// that reach the member.
@(private = "file")
add_member_variant :: proc(
	variant: Decl_Variant,
	type_name, member_name: string,
	symbol: Symbol,
	covered: map[string]struct{},
	found: ^[dynamic]Symbol,
	problem: ^string,
) {
	src := string(variant.document.text[:variant.document.used_text])
	for name, j in variant.decl.names {
		if common.get_token_range(name, src) != variant.symbol.range do continue
		at := fmt.tprintf("`%s` at %s", type_name, declared_at(variant.symbol))
		variant_value := variant.decl.values[j] if j < len(variant.decl.values) else nil
		others, is_type := type_members(variant_value)
		if !is_type {
			if named := named_type(variant_value); named == nil || named.name not_in covered {
				problem^ = fmt.tprintf(
					"the platform variant %s is no struct, enum or bit_field type, so its member `%s` cannot be renamed",
					at,
					member_name,
				)
			}
			continue
		}
		own := false
		next: for other in others {
			if other.name != member_name do continue
			own = true
			field := symbol
			field.uri = variant.symbol.uri
			field.range = common.get_token_range(other^, src)
			for known in found {
				if known.uri == field.uri && known.range == field.range do continue next
			}
			append(found, field)
		}
		if !own && has_using_field(variant_value, covered) {
			problem^ = fmt.tprintf(
				"the platform variant %s may reach `%s` through a `using` field, which the rename cannot change",
				at,
				member_name,
			)
		}
	}
}

// The package-level declarations that alias the type that reaching names or embed it with `using`, read in its file
// and, unless it is private to its file, in the other files of its package that mention its name.
@(private = "file")
type_users :: proc(h: ^Call_Hierarchy, reaching: Decl_Variant) -> []Decl_Variant {
	home := reaching.document
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, home.fullpath)
	if !file_private(home, reaching.decl) {
		for sibling in package_siblings(home, h.files) {
			slashed, _ := filepath.replace_separators(sibling, '/', context.temp_allocator)
			if file_mentions(h, slashed, reaching.symbol.name) do append(&paths, slashed)
		}
	}
	users := make([dynamic]Decl_Variant, context.temp_allocator)
	for fullpath in paths {
		document := hierarchy_document(h, common.create_uri(fullpath, context.temp_allocator).uri)
		if document == nil || document.ast.pkg_name != home.ast.pkg_name {
			continue
		}
		if parser.parse_file_tags(document.ast, context.temp_allocator).ignore {
			continue
		}
		src := string(document.text[:document.used_text])
		for decl in top_level_value_decls(document.ast) {
			for value, i in decl.values {
				if i >= len(decl.names) do break
				named := named_type(value)
				if (named == nil || named.name != reaching.symbol.name) && !embeds(value, reaching.symbol.name) {
					continue
				}
				user := reaching.symbol
				user.uri = document.uri.uri
				user.range = common.get_token_range(decl.names[i], src)
				user.name = final_name(decl.names[i])
				append(&users, Decl_Variant{document, decl, user})
			}
		}
	}
	return users[:]
}

// The identifier that type_expr names after its `distinct`, parentheses and pointers, nil when there is none.
@(private = "file")
named_type :: proc(type_expr: ^ast.Expr) -> ^ast.Ident {
	expr := strip_parens_and_pointers(type_expr)
	for expr != nil {
		distinct_type := expr.derived.(^ast.Distinct_Type) or_break
		expr = strip_parens_and_pointers(distinct_type.type)
	}
	if expr == nil do return nil
	ident, _ := expr.derived.(^ast.Ident)
	return ident
}

// Whether type_expr, a struct type or a distinct one, has a `using` field of the type named name.
@(private = "file")
embeds :: proc(type_expr: ^ast.Expr, name: string) -> bool {
	struct_type := struct_of(type_expr)
	if struct_type == nil || struct_type.fields == nil do return false
	for field in struct_type.fields.list {
		if .Using not_in field.flags do continue
		if named := named_type(field.type); named != nil && named.name == name do return true
	}
	return false
}

// Whether type_expr, a struct type or a distinct one, has a `using` field whose type is none of the types that
// covered names.
@(private = "file")
has_using_field :: proc(type_expr: ^ast.Expr, covered: map[string]struct{}) -> bool {
	struct_type := struct_of(type_expr)
	if struct_type == nil || struct_type.fields == nil do return false
	for field in struct_type.fields.list {
		if .Using not_in field.flags do continue
		if named := named_type(field.type); named == nil || named.name not_in covered do return true
	}
	return false
}

// The struct type of type_expr, a struct type or a distinct one, nil for any other type.
@(private = "file")
struct_of :: proc(type_expr: ^ast.Expr) -> ^ast.Struct_Type {
	if type_expr == nil do return nil
	#partial switch t in type_expr.derived {
	case ^ast.Distinct_Type:
		return struct_of(t.type)
	case ^ast.Struct_Type:
		return t
	}
	return nil
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
file_mentions :: proc(h: ^Call_Hierarchy, fullpath, name: string) -> bool {
	if open := &document_storage.documents[fullpath]; open != nil && open.client_owned {
		return strings.contains(string(open.text[:open.used_text]), name)
	}
	for file in h.files {
		if file.fullpath == fullpath do return strings.contains(file.text, name)
	}
	data, err := os.read_entire_file(fullpath, context.temp_allocator)
	return err == nil && strings.contains(string(data), name)
}

// Names of the top-level declarations of document that are private to its file.
file_private_names :: proc(document: ^Document) -> map[string]struct{} {
	names := make(map[string]struct{}, context.temp_allocator)
	whole_file := parser.parse_file_tags(document.ast, context.temp_allocator).private == .File
	for decl in top_level_value_decls(document.ast) {
		if whole_file || is_file_private(decl.attributes[:]) {
			for name in decl.names {
				names[final_name(name)] = {}
			}
		}
	}
	return names
}

// Whether decl of document is private to its file, by its attribute or by `#+private file`.
file_private :: proc(document: ^Document, decl: ^ast.Value_Decl) -> bool {
	tags := parser.parse_file_tags(document.ast, context.temp_allocator)
	return is_file_private(decl.attributes[:]) || tags.private == .File
}
