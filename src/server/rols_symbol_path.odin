package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

// Where a symbol path points: the file and the 1-based line and byte column of the declared name.
Symbol_Path_Target :: struct {
	fullpath:     string,
	line, column: int,
}

// Resolves names, `Name` or `Name.Member`, against the top-level declarations of the package in dir.
// files, when given, replaces the directory listing. Member is a struct field, an enum member or a
// bit_field field. reason says why the path does not resolve: not found, ambiguous, or a member of a
// type that has no members.
find_symbol_path :: proc(
	dir: string,
	names: string,
	files: []Package_File = {},
) -> (
	target: Symbol_Path_Target,
	reason: string,
	ok: bool,
) {
	parts := strings.split(names, ".", context.temp_allocator)
	if len(parts) > 2 || slice.contains(parts, "") {
		return {}, fmt.tprintf("`%s` is not Name or Name.Member after the package %s", names, dir), false
	}
	name := parts[0]

	sources := files
	if len(sources) == 0 {
		sources = package_dir_files(dir)
	}

	Found :: struct {
		fullpath: string,
		ident:    ^ast.Ident,
		value:    ^ast.Expr,
	}
	found := make([dynamic]Found, context.temp_allocator)
	for source in sources {
		file, parsed := parse_symbol_path_file(source)
		if !parsed {
			continue
		}
		for decl in top_level_value_decls(file) {
			for name_expr, i in decl.names {
				ident := name_expr.derived.(^ast.Ident) or_continue
				if ident.name == name {
					value := decl.values[i] if len(decl.values) == len(decl.names) else nil
					append(&found, Found{source.fullpath, ident, value})
				}
			}
		}
	}

	if len(found) == 0 {
		return {}, fmt.tprintf("no top-level declaration `%s` in the package %s", name, dir), false
	}
	if len(found) > 1 {
		places := make([dynamic]string, context.temp_allocator)
		for f in found {
			append(&places, fmt.tprintf("%s:%d:%d", f.fullpath, f.ident.pos.line, f.ident.pos.column))
		}
		return {},
			fmt.tprintf(
				"`%s` is declared %d times in the package %s, at %s; pass FILE:LINE:COL instead",
				name,
				len(found),
				dir,
				strings.join(places[:], ", ", context.temp_allocator),
			),
			false
	}

	decl := found[0]
	if len(parts) == 1 {
		return {decl.fullpath, decl.ident.pos.line, decl.ident.pos.column}, "", true
	}

	member := parts[1]
	members, has_members := type_members(decl.value)
	if !has_members {
		return {},
			fmt.tprintf("`%s` is not a struct, enum or bit_field type, so it has no member `%s`", name, member),
			false
	}
	for ident in members {
		if ident.name == member {
			return {decl.fullpath, ident.pos.line, ident.pos.column}, "", true
		}
	}
	return {}, fmt.tprintf("`%s` has no member `%s`", name, member), false
}

// The member names of a struct, enum or bit_field type expression; has is false for any other expression.
type_members :: proc(type_expr: ^ast.Expr) -> (members: []^ast.Ident, has: bool) {
	if type_expr == nil {
		return
	}
	list := make([dynamic]^ast.Ident, context.temp_allocator)
	#partial switch t in type_expr.derived {
	case ^ast.Distinct_Type:
		return type_members(t.type)
	case ^ast.Struct_Type:
		if t.fields != nil {
			for field in t.fields.list {
				for name in field.names {
					if ident, ok := name.derived.(^ast.Ident); ok {
						append(&list, ident)
					}
				}
			}
		}
	case ^ast.Enum_Type:
		for field in t.fields {
			#partial switch f in field.derived {
			case ^ast.Ident:
				append(&list, f)
			case ^ast.Field_Value:
				if ident, ok := f.field.derived.(^ast.Ident); ok {
					append(&list, ident)
				}
			}
		}
	case ^ast.Bit_Field_Type:
		for field in t.fields {
			if ident, ok := field.name.derived.(^ast.Ident); ok {
				append(&list, ident)
			}
		}
	case:
		return
	}
	return list[:], true
}

// The .odin files of dir that build on this target, as the indexer reads them.
@(private = "file")
package_dir_files :: proc(dir: string) -> []Package_File {
	matches, _ := filepath.glob(path.join({dir, "*.odin"}, context.temp_allocator), context.temp_allocator)
	files := make([dynamic]Package_File, context.temp_allocator)
	for fullpath in matches {
		if skip_file(filepath.base(fullpath)) {
			continue
		}
		data, err := os.read_entire_file(fullpath, context.temp_allocator)
		if err == nil {
			append(&files, Package_File{fullpath, string(data)})
		}
	}
	return files[:]
}

@(private = "file")
parse_symbol_path_file :: proc(source: Package_File) -> (file: ast.File, ok: bool) {
	context.allocator = context.temp_allocator
	p := parser.Parser {
		flags = {.Optional_Semicolons},
		err   = log_error_handler,
		warn  = log_warning_handler,
	}
	pkg := new(ast.Package)
	pkg.kind = .Normal
	pkg.fullpath = source.fullpath
	file = ast.File {
		fullpath = source.fullpath,
		src      = source.text,
		pkg      = pkg,
	}
	return file, parse_file(&p, &file)
}
