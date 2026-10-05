package server

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "src:common"

// One match of `ols query find`: the LSP WorkspaceSymbol fields, and whether the declaration is private
// (`@(private)`, `@(private = "file")` or a `#+private` file) or sits in a file that the current target does
// not build.
Find_Symbol :: struct {
	name:          string,
	kind:          SymbolKind,
	location:      common.Location,
	private:       bool,
	otherPlatform: bool,
}

// The directories below the workspace folders, and the folders themselves, that hold .odin files, sorted.
// The workspace filter, the `exclude_path` profile, node_modules and hidden directories such as .git leave out.
workspace_package_dirs :: proc(config: ^common.Config, allocator := context.temp_allocator) -> []string {
	dirs := make([dynamic]string, allocator)
	for workspace in config.workspace_folders {
		uri := common.parse_uri(workspace.uri, context.temp_allocator) or_continue
		append(&dirs, ..package_dirs_below(uri.path, uri.path, config, allocator))
	}
	slice.sort(dirs[:])
	return slice.unique(dirs[:])
}

// The directories below start, and start itself, that hold .odin files, sorted, left out as for
// workspace_package_dirs. root is the workspace folder whose filter applies.
package_dirs_below :: proc(
	start, root: string,
	config: ^common.Config,
	allocator := context.temp_allocator,
) -> []string {
	dirs := make([dynamic]string, allocator)
	filter := common.workspace_filter_make(root, config, context.temp_allocator)

	candidates := make([dynamic]string, context.temp_allocator)
	append(&candidates, start)
	w := os.walker_create(start)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if info.type != .Directory do continue
		dir, _ := filepath.replace_separators(info.fullpath, '/', context.temp_allocator)
		name := filepath.base(dir)
		hidden := strings.has_prefix(name, ".")
		if hidden || slice.contains(dir_blacklist, name) || common.workspace_filter_skip_dir(&filter, info.fullpath) {
			os.walker_skip_dir(&w)
			continue
		}
		append(&candidates, dir)
	}

	for dir in candidates {
		matches, _ := filepath.glob(fmt.tprintf("%v/*.odin", dir), context.temp_allocator)
		if len(matches) > 0 && !excluded_by_profile(config, dir) {
			append(&dirs, strings.clone(dir, allocator))
		}
	}
	slice.sort(dirs[:])
	return dirs[:]
}

@(private = "file")
excluded_by_profile :: proc(config: ^common.Config, dir: string) -> bool {
	lower_dir := strings.to_lower(dir, context.temp_allocator)
	for exclude_path in config.profile.exclude_path {
		exclude, _ := filepath.replace_separators(exclude_path, '/', context.temp_allocator)
		lower := strings.to_lower(exclude, context.temp_allocator)
		if strings.has_suffix(lower, "**") {
			if strings.contains(lower_dir, strings.trim_suffix(strings.trim_suffix(lower, "**"), "/")) do return true
		} else if lower_dir == lower {
			return true
		}
	}
	return false
}

@(private = "file")
Find_Hit :: struct {
	symbol: Find_Symbol,
	score:  f32,
}

// The declarations of the workspace whose names match query, best match first, at most limit. Unlike the
// workspace symbols of the LSP, which come from the index of the current target, it reads every .odin file, so
// it also reports private declarations and those of files that only another target builds. A file that no
// target builds (`#+build ignore`) and one that does not parse are left out.
find_symbols :: proc(query: string, config: ^common.Config, limit := 100) -> []Find_Symbol {
	matchers := make([dynamic]^common.FuzzyMatcher, context.temp_allocator)
	for field in strings.fields(query, context.temp_allocator) {
		append(&matchers, common.make_fuzzy_matcher(field))
	}
	base := base_target(config.checker_args)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return {}
	defer virtual.arena_destroy(&arena)

	hits := make([dynamic]Find_Hit, context.temp_allocator)
	for dir in workspace_package_dirs(config) {
		files, _ := filepath.glob(fmt.tprintf("%v/*.odin", dir), context.temp_allocator)
		for file in files {
			data, err := os.read_entire_file(file, context.temp_allocator)
			if err != nil do continue
			text := string(data)
			other_platform := false
			if !builds_on(file, text, base) {
				if _, need := target_for_file(file, text, base); need != .Other do continue
				other_platform = true
			}

			context.allocator = virtual.arena_allocator(&arena)
			if parsed, parsed_ok := parse_syntax(file, text); parsed_ok {
				private_file := parser.parse_file_tags(parsed, context.allocator).private != .Public
				uri := common.create_uri(file, context.temp_allocator).uri
				for stmt in parsed.decls {
					collect_find_hits(&hits, matchers[:], stmt, &parsed, uri, private_file, other_platform)
				}
			}
			virtual.arena_free_all(&arena)
		}
	}

	slice.sort_by(hits[:], proc(a, b: Find_Hit) -> bool {
		if a.score > b.score do return true
		if a.score < b.score do return false
		if a.symbol.location.uri != b.symbol.location.uri do return a.symbol.location.uri < b.symbol.location.uri
		return a.symbol.location.range.start.line < b.symbol.location.range.start.line
	})
	result := make([]Find_Symbol, min(limit, len(hits)), context.temp_allocator)
	for &symbol, i in result {
		symbol = hits[i].symbol
	}
	return result
}

@(private = "file")
collect_find_hits :: proc(
	hits: ^[dynamic]Find_Hit,
	matchers: []^common.FuzzyMatcher,
	stmt: ^ast.Stmt,
	file: ^ast.File,
	uri: string,
	private_file, other_platform: bool,
) {
	if stmt == nil do return
	#partial switch s in stmt.derived {
	case ^ast.Value_Decl:
		private := private_file || slice.contains(attribute_names(s.attributes[:]), "private")
		for name, i in s.names {
			ident := name.derived.(^ast.Ident) or_continue
			score, ok := score_name(matchers, ident.name)
			if !ok do continue
			append(
				hits,
				Find_Hit {
					symbol = {
						name = ident.name,
						kind = find_kind(s, i),
						location = {uri = uri, range = common.get_token_range(ident, file.src)},
						private = private,
						otherPlatform = other_platform,
					},
					score = score,
				},
			)
		}
	case ^ast.When_Stmt:
		collect_find_hits(hits, matchers, s.body, file, uri, private_file, other_platform)
		collect_find_hits(hits, matchers, s.else_stmt, file, uri, private_file, other_platform)
	case ^ast.Block_Stmt:
		for inner in s.stmts {
			collect_find_hits(hits, matchers, inner, file, uri, private_file, other_platform)
		}
	case ^ast.Foreign_Block_Decl:
		collect_find_hits(hits, matchers, s.body, file, uri, private_file, other_platform)
	}
}

// The kind the index gives name number i of decl: procedures and groups are functions, structs are
// structs, enums and unions are enums, other types are classes, variables are variables, the rest constants.
@(private = "file")
find_kind :: proc(decl: ^ast.Value_Decl, i: int) -> SymbolKind {
	if decl.is_mutable do return .Variable
	if i >= len(decl.values) do return .Constant
	value := decl.values[i]
	if distinct_type, ok := value.derived.(^ast.Distinct_Type); ok && distinct_type.type != nil {
		value = distinct_type.type
	}
	#partial switch _ in value.derived {
	case ^ast.Proc_Lit, ^ast.Proc_Group:
		return .Function
	case ^ast.Struct_Type, ^ast.Bit_Field_Type:
		return .Struct
	case ^ast.Enum_Type, ^ast.Union_Type:
		return .Enum
	case ^ast.Array_Type,
	     ^ast.Dynamic_Array_Type,
	     ^ast.Map_Type,
	     ^ast.Pointer_Type,
	     ^ast.Multi_Pointer_Type,
	     ^ast.Bit_Set_Type,
	     ^ast.Matrix_Type,
	     ^ast.Proc_Type,
	     ^ast.Typeid_Type:
		return .Class
	}
	return .Constant
}
