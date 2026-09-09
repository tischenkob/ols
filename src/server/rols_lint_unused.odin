package server

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:common"

Package_File :: struct {
	fullpath: string,
	text:     string,
}

@(private = "file")
Decl_Key :: struct {
	uri:   string,
	range: common.Range,
}

@(private = "file")
Candidate :: struct {
	symbol: Symbol,
	// Byte extent of the declaring Value_Decl; references inside it (the name itself, recursion) do not count.
	start:  int,
	end:    int,
	used:   bool,
}

@(private = "file")
MAX_FILES :: 100
@(private = "file")
MAX_BYTES :: mem.Megabyte * 3 / 2

// Cross-file, so it runs on save only; the index is thread local and must be fresh for the saved file.
lint_unused_declarations :: proc(document: ^Document, config: ^common.Config) {
	if !config.enable_diagnostics || !config.enable_lint_unused_declaration do return

	matches, err := filepath.glob(fmt.tprintf("%v/*.odin", document.package_name), context.temp_allocator)
	if err != nil && err != .Not_Exist do return

	files := make([dynamic]Package_File, context.temp_allocator)
	total := 0
	for fullpath in matches {
		if skip_file(filepath.base(fullpath)) do continue
		text: string
		if open := &document_storage.documents[fullpath]; open != nil && open.client_owned {
			text = string(open.text[:open.used_text])
		} else {
			data, read_err := os.read_entire_file(fullpath, context.temp_allocator)
			if read_err != nil do continue
			text = string(data)
		}
		total += len(text)
		append(&files, Package_File{fullpath, text})
	}

	if len(files) > MAX_FILES || total > MAX_BYTES {
		log.infof("unused declaration lint skipped for %v: %d files, %d bytes", document.package_name, len(files), total)
		return
	}

	diagnostics, ok := unused_declarations(document.package_name, files[:], config)
	if !ok do return
	for file in files {
		remove_diagnostics(.Unused_Decl, common.create_uri(file.fullpath, context.temp_allocator).uri)
	}
	for uri, diags in diagnostics {
		for d in diags do add_diagnostics(.Unused_Decl, uri, d)
	}
}

// Private symbols of pkg that no file in files references outside their own declaration, keyed by uri.
// Fails when a file does not parse, since a missing file would make every symbol it uses look unused.
unused_declarations :: proc(
	pkg: string,
	files: []Package_File,
	config: ^common.Config,
) -> (
	diagnostics: map[string][dynamic]Diagnostic,
	ok: bool,
) {
	if !config.enable_lint_unused_declaration do return diagnostics, true
	diagnostics = make(map[string][dynamic]Diagnostic, context.temp_allocator)

	candidates := make(map[Decl_Key]Candidate, context.temp_allocator)

	// Heap-backed so destroy returns memory; ASTs live for the whole pass, resolution only per file.
	ast_arena, scratch: runtime.Arena
	_ = runtime.arena_init(&ast_arena, mem.Megabyte * 8, runtime.default_allocator())
	defer runtime.arena_destroy(&ast_arena)
	_ = runtime.arena_init(&scratch, mem.Megabyte * 8, runtime.default_allocator())
	defer runtime.arena_destroy(&scratch)

	documents := make([dynamic]Document, len(files), context.temp_allocator)
	for file, i in files {
		context.allocator = runtime.arena_allocator(&ast_arena)
		documents[i] = parse_package_file(file, config) or_return
	}

	// After parsing: parse_imports may index new packages, which rehashes the packages map.
	indexed := (&indexer.index.collection.packages[pkg]) or_return
	for &document in documents {
		uri := document.uri.uri

		for decl, attributes in top_level_decls(document.ast) {
			names := attribute_names(attributes)
			for name in decl.names {
				ident := name.derived.(^ast.Ident) or_continue
				symbol := indexed.symbols[ident.name] or_continue
				if symbol.uri != uri || symbol.flags & {.PrivateFile, .PrivatePackage} == {} do continue
				if ident.name == "main" || strings.has_prefix(ident.name, "_") || is_kept_alive(names) do continue
				#partial switch symbol.type {
				case .Package, .Field, .EnumMember, .Keyword:
					continue
				}
				candidates[{uri, symbol.range}] = Candidate{symbol = symbol, start = decl.pos.offset, end = decl.end.offset}
			}
		}
	}

	for &document in documents {
		context.allocator = runtime.arena_allocator(&scratch)
		defer runtime.arena_free_all(&scratch)
		uri := document.uri.uri
		for _, hit in resolve_entire_file_for_references(&document, context.allocator, .Identifier, "") {
			candidate := (&candidates[{hit.symbol.uri, hit.symbol.range}]) or_continue
			offset := hit.node.pos.offset
			if hit.symbol.uri == uri && candidate.start <= offset && offset < candidate.end do continue
			candidate.used = true
		}
	}

	for key, candidate in candidates {
		if candidate.used do continue
		diags := &diagnostics[key.uri]
		if diags == nil {
			diagnostics[strings.clone(key.uri, context.temp_allocator)] = make(
				[dynamic]Diagnostic,
				context.temp_allocator,
			)
			diags = &diagnostics[key.uri]
		}
		append(
			diags,
			Diagnostic {
				range = candidate.symbol.range,
				severity = .Hint,
				code = "unused-declaration",
				message = fmt.tprintf(
					"%s %s is never used in package %s",
					kind_name(candidate.symbol),
					candidate.symbol.name,
					filepath.base(pkg),
				),
				tags = {.Unnecessary},
			},
		)
	}

	return diagnostics, true
}

parse_package_file :: proc(file: Package_File, config: ^common.Config) -> (document: Document, ok: bool) {
	p := parser.Parser {
		flags = {.Optional_Semicolons},
		err   = log_error_handler,
		warn  = log_warning_handler,
	}

	pkg := new(ast.Package)
	pkg.kind = .Normal
	pkg.fullpath = file.fullpath
	pkg.name = filepath.base(filepath.dir(file.fullpath))

	document.ast = ast.File {
		fullpath = file.fullpath,
		src      = file.text,
		pkg      = pkg,
	}
	if !parse_file(&p, &document.ast) || document.ast.syntax_error_count > 0 {
		return {}, false
	}

	document.uri = common.create_uri(file.fullpath, context.allocator)
	document.text = transmute([]u8)file.text
	document.used_text = len(file.text)
	document_setup(&document)
	parse_imports(&document, config)
	return document, true
}

// Value declarations at file scope, including those under `when`; foreign blocks are skipped.
top_level_decls :: proc(file: ast.File) -> map[^ast.Value_Decl][]^ast.Attribute {
	decls := make(map[^ast.Value_Decl][]^ast.Attribute, context.temp_allocator)
	for decl in file.decls do collect(decl, &decls)
	return decls

	collect :: proc(stmt: ^ast.Stmt, decls: ^map[^ast.Value_Decl][]^ast.Attribute) {
		if stmt == nil do return
		#partial switch s in stmt.derived {
		case ^ast.Value_Decl:
			decls[s] = s.attributes[:]
		case ^ast.When_Stmt:
			collect(s.body, decls)
			collect(s.else_stmt, decls)
		case ^ast.Block_Stmt:
			for inner in s.stmts do collect(inner, decls)
		}
	}
}

@(private = "file")
is_kept_alive :: proc(attribute_names: []string) -> bool {
	for name in attribute_names {
		switch name {
		case "export", "test", "init", "fini", "link_name", "linkage":
			return true
		}
	}
	return false
}

@(private = "file")
kind_name :: proc(symbol: Symbol) -> string {
	#partial switch symbol.type {
	case .Function:
		return "procedure"
	case .Type_Function:
		return "procedure group"
	case .Struct:
		return "struct"
	case .Union:
		return "union"
	case .Enum:
		return "enum"
	case .Type:
		return "type"
	case .Constant:
		return "constant"
	case .Variable:
		return "variable"
	}
	return "variable" if .Mutable in symbol.flags else "constant"
}
