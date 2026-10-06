package server

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:strings"

import "src:common"

// A file that the host does not build looks names up in the files of the target that builds it first, so that
// `socket_linux.odin` on darwin reaches `errors_linux.odin` and not the host's `errors_posix.odin`. The index holds
// only the files that the host builds. Each other target gets its own symbol collection of the files that the host
// does not build, filled per package on the first lookup that needs that package.

// A file that the host does not build and that is not on disk, such as a test source, with its text.
@(private = "file")
Unsaved_File :: struct {
	fullpath, uri, text: string,
}

@(private = "file")
Target_Key :: struct {
	os:   runtime.Odin_OS_Type,
	arch: runtime.Odin_Arch_Type,
}

// The declarations that one target builds and the host does not. The keys of built are strings of the collection.
@(private = "file")
Target_Index :: struct {
	collection: SymbolCollection,
	built:      map[string]bool,
}

// The target that builds a file, computed for host. target is nil when host builds the file or no target does.
@(private = "file")
File_Target :: struct {
	host:   parser.Build_Target,
	target: Maybe(parser.Build_Target),
}

@(private = "file")
Excluded_Files :: struct {
	allocator: mem.Allocator,
	unsaved:   map[string][dynamic]Unsaved_File, // package directory to its unsaved files
	targets:   map[string]File_Target, // file path to its target
	indexes:   map[Target_Key]^Target_Index,
}

@(private = "file", thread_local)
excluded: Excluded_Files

// The allocator of the state, which a mutation fetches first. The maps get it here: a map that its first insert
// creates takes context.allocator, which is a document arena in parse_document.
@(private = "file")
excluded_allocator :: proc() -> mem.Allocator {
	if excluded.allocator.procedure == nil {
		excluded.allocator = indexer.index.collection.allocator
		if excluded.allocator.procedure == nil do excluded.allocator = runtime.heap_allocator()
		excluded.unsaved = make(map[string][dynamic]Unsaved_File, excluded.allocator)
		excluded.targets = make(map[string]File_Target, excluded.allocator)
		excluded.indexes = make(map[Target_Key]^Target_Index, excluded.allocator)
	}
	return excluded.allocator
}

// The symbol `name` of `pkg` that a lookup from current_file finds first, when the host does not build current_file:
// the declaration of the target that builds it. A declaration of an inactive `when` branch of that target yields to
// a declaration in the index.
lookup_other_target :: proc(
	name, pkg, current_file, current_pkg, current_file_uri: string,
) -> (
	symbol: Symbol,
	found: bool,
) {
	target := file_target(current_file) or_return
	index := target_index(target)
	if pkg not_in index.built do build_target_package(index, target, pkg)
	symbol = index.collection.packages[pkg].symbols[name] or_return
	if should_skip_private_symbol(symbol, current_pkg, current_file_uri) do return {}, false
	if .Fallback in symbol.flags {
		if host, ok := memory_index_lookup(&indexer.index, name, pkg);
		   ok && !should_skip_private_symbol(host, current_pkg, current_file_uri) {
			return {}, false
		}
	}
	return symbol, true
}

// Records the target of a parsed document, so lookups need not parse it again.
note_document_target :: proc(document: ^Document) {
	host := host_target()
	name, need := parsed_target_for_file(document.ast, host)
	set_file_target(document.fullpath, host, name, need)
}

// Keeps a file that the host does not build and that is not on disk, for the targets that build it. A file on disk
// is found again from its directory.
note_excluded_file :: proc(collection: ^SymbolCollection, file: ast.File, uri: string) {
	if collection != &indexer.index.collection {
		return
	}
	tags := parser.parse_file_tags(file, context.temp_allocator)
	if (!skip_file(filepath.base(file.fullpath)) && should_collect_file(tags)) || os.exists(file.fullpath) {
		return
	}
	allocator := excluded_allocator()
	forward, _ := filepath.replace_separators(file.fullpath, '/', context.temp_allocator)
	dir := path.dir(forward, context.temp_allocator)
	files, found := &excluded.unsaved[dir]
	if !found {
		files = map_insert(&excluded.unsaved, strings.clone(dir, allocator), make([dynamic]Unsaved_File, allocator))
	}
	forget_unsaved(files, forward)
	append(
		files,
		Unsaved_File {
			fullpath = strings.clone(forward, allocator),
			uri = strings.clone(uri, allocator),
			text = strings.clone(file.src, allocator),
		},
	)
}

// Drops what the index of other targets knows of fullpath and of its package, before a reindex or removal of it.
forget_excluded_file :: proc(fullpath: string) {
	forward, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	dir := path.dir(forward, context.temp_allocator)
	if files, ok := &excluded.unsaved[dir]; ok {
		forget_unsaved(files, forward)
	}
	for file in ([2]string{fullpath, forward}) {
		if file in excluded.targets {
			key, _ := delete_key(&excluded.targets, file)
			delete(key, excluded.allocator)
		}
	}
	for _, index in excluded.indexes {
		if dir not_in index.built do continue
		delete_key(&index.built, dir)
		if dir in index.collection.packages {
			_, pkg := delete_key(&index.collection.packages, dir)
			delete_symbol_package(pkg, index.collection.allocator)
		}
	}
}

// Frees everything, as free_index frees the index.
free_excluded :: proc() {
	allocator := excluded.allocator
	for dir, files in excluded.unsaved {
		for file in files do free_unsaved(file)
		delete(files)
		delete(dir, allocator)
	}
	delete(excluded.unsaved)
	for file in excluded.targets do delete(file, allocator)
	delete(excluded.targets)
	for _, index in excluded.indexes {
		delete(index.built)
		delete_symbol_collection(index.collection)
		free(index, allocator)
	}
	delete(excluded.indexes)
	excluded = {}
}

@(private = "file")
forget_unsaved :: proc(files: ^[dynamic]Unsaved_File, fullpath: string) {
	for i := len(files) - 1; i >= 0; i -= 1 {
		if files[i].fullpath != fullpath do continue
		free_unsaved(files[i])
		ordered_remove(files, i)
	}
}

@(private = "file")
free_unsaved :: proc(file: Unsaved_File) {
	delete(file.fullpath, excluded.allocator)
	delete(file.uri, excluded.allocator)
	delete(file.text, excluded.allocator)
}

@(private = "file")
set_file_target :: proc(
	fullpath: string,
	host: parser.Build_Target,
	name: string,
	need: Target_Need,
) -> (
	entry: File_Target,
) {
	allocator := excluded_allocator()
	entry.host = host
	if need == .Other {
		entry.target, _ = parse_target(name)
	}
	if fullpath in excluded.targets {
		excluded.targets[fullpath] = entry
	} else {
		excluded.targets[strings.clone(fullpath, allocator)] = entry
	}
	return
}

// The target that builds fullpath when the host does not. A lookup asks once per identifier, so the answer is kept
// until the file changes or the host does.
@(private = "file")
file_target :: proc(fullpath: string) -> (parser.Build_Target, bool) {
	if fullpath == "" {
		return {}, false
	}
	host := host_target()
	if entry, ok := excluded.targets[fullpath]; ok && entry.host == host {
		return entry.target.?
	}
	text, _ := file_text(fullpath)
	name, need := target_for_file(fullpath, text, host)
	return set_file_target(fullpath, host, name, need).target.?
}

// The text of an open document, else of an unsaved file, else of the file on disk, in temp memory.
@(private = "file")
file_text :: proc(fullpath: string) -> (string, bool) {
	if document, ok := document_storage.documents[fullpath]; ok && document.text != nil {
		return string(document.text[:document.used_text]), true
	}
	forward, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	unsaved := excluded.unsaved[path.dir(forward, context.temp_allocator)]
	for file in unsaved {
		if file.fullpath == forward do return file.text, true
	}
	data, err := os.read_entire_file(fullpath, context.temp_allocator)
	return string(data), err == nil
}

@(private = "file")
target_index :: proc(target: parser.Build_Target) -> ^Target_Index {
	key := Target_Key{target.os, target.arch}
	if index, ok := excluded.indexes[key]; ok {
		return index
	}
	allocator := excluded_allocator()
	index := new(Target_Index, allocator)
	index.collection = make_symbol_collection(indexer.index.collection.config, allocator)
	index.built = make(map[string]bool, allocator)
	excluded.indexes[key] = index
	return index
}

// Collects the files of pkg that target builds and the host does not, as try_build_package collects the others.
@(private = "file")
build_target_package :: proc(index: ^Target_Index, target: parser.Build_Target, pkg: string) {
	index.built[get_index_unique_string(&index.collection, pkg)] = true
	host := host_target()
	saved := when_target
	when_target = target
	defer when_target = saved

	arena: runtime.Arena
	_ = runtime.arena_init(&arena, mem.Megabyte, runtime.heap_allocator())
	defer runtime.arena_destroy(&arena)
	context.allocator = runtime.arena_allocator(&arena)

	// A range over a missing map element dereferences nil, so the element is copied first.
	unsaved := excluded.unsaved[pkg]
	for file in unsaved {
		collect_target_file(index, file.fullpath, file.uri, file.text, host)
		runtime.arena_free_all(&arena)
	}
	matches, _ := filepath.glob(fmt.tprintf("%v/*.odin", pkg), context.temp_allocator)
	for fullpath in matches {
		// host_target is target here, so this skips the names of a third platform.
		if skip_file(filepath.base(fullpath)) do continue
		data, err := os.read_entire_file(fullpath, context.allocator)
		if err == nil {
			collect_target_file(
				index,
				fullpath,
				common.create_uri(fullpath, context.allocator).uri,
				string(data),
				host,
			)
		}
		runtime.arena_free_all(&arena)
	}
}

@(private = "file")
collect_target_file :: proc(index: ^Target_Index, fullpath, uri, text: string, host: parser.Build_Target) {
	if builds_on(fullpath, text, host) {
		return
	}
	p := parser.Parser {
		flags = {.Optional_Semicolons},
	}
	dir := filepath.base(filepath.dir(fullpath))
	pkg := new(ast.Package)
	pkg.kind = .Runtime if dir == "runtime" || strings.contains(fullpath, "base/runtime") else .Normal
	pkg.fullpath = fullpath
	pkg.name = dir
	file := ast.File {
		fullpath = fullpath,
		src      = text,
		pkg      = pkg,
	}
	if parse_file(&p, &file) && file.syntax_error_count == 0 {
		// collect_globals keeps only the files that target builds.
		collect_symbols(&index.collection, file, uri)
	}
}
