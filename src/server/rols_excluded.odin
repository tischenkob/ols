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

// A file that the host does not build looks names up in the files of the target that builds it, so that
// `socket_linux.odin` on darwin reaches `errors_linux.odin` and not the host's `errors_posix.odin`. The index holds
// the files that the host builds. Each other target gets its own symbol collection of every file that it builds,
// with `when` evaluated for it, filled per package on the first lookup into that package.

// A file of the index that is not on disk, such as a test source, with its text.
@(private = "file")
Unsaved_File :: struct {
	fullpath, text: string,
}

@(private = "file")
Target_Key :: struct {
	os:   runtime.Odin_OS_Type,
	arch: runtime.Odin_Arch_Type,
}

// The declarations that one target builds. The keys of built are strings of the collection.
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

// The symbol `name` of `pkg` for a lookup from current_file, when the host does not build current_file: the
// declaration of the target that builds it. handled is false when the index answers instead: the host builds
// current_file, or that target builds no file of pkg.
lookup_other_target :: proc(
	name, pkg, current_file, current_pkg, current_file_uri: string,
) -> (
	symbol: Symbol,
	found: bool,
	handled: bool,
) {
	symbols := other_target_package(pkg, current_file) or_return
	symbol, found = symbols.symbols[name]
	if found && should_skip_private_symbol(symbol, current_pkg, current_file_uri) {
		return {}, false, true
	}
	return symbol, found, true
}

// The package pkg of the index for a lookup from current_file: that of the target that builds current_file when
// the host does not and a lookup has collected pkg for that target, else that of the index. Fake methods ask this
// for every indexed package, so it collects nothing itself.
package_for_file :: proc(pkg, current_file: string) -> (SymbolPackage, bool) {
	if target, ok := file_target(current_file); ok {
		if symbols, built := target_index(target).collection.packages[pkg]; built {
			return symbols, true
		}
	}
	return indexer.index.collection.packages[pkg]
}

// fuzzy_search over the declarations of the target that builds current_file, when the host does not.
fuzzy_search_other_target :: proc(
	name: string,
	pkgs: []string,
	current_file: string,
	resolve_fields: bool,
	limit: int,
) -> (
	results: []FuzzyResult,
	ok: bool,
	handled: bool,
) {
	target := file_target(current_file) or_return
	index := target_index(target)
	for pkg in pkgs {
		if pkg not_in index.built do build_target_package(index, target, pkg)
	}
	memory_index := make_memory_index(index.collection)
	results, ok = memory_index_fuzzy_search(&memory_index, name, pkgs, current_file, resolve_fields, limit = limit)
	return results, ok, true
}

@(private = "file")
other_target_package :: proc(pkg, current_file: string) -> (symbols: SymbolPackage, ok: bool) {
	target := file_target(current_file) or_return
	index := target_index(target)
	if pkg not_in index.built do build_target_package(index, target, pkg)
	return index.collection.packages[pkg]
}

// Records the target of a parsed document, so lookups need not parse it again.
note_document_target :: proc(document: ^Document) {
	host := host_target()
	name, need := parsed_target_for_file(document.ast, host)
	set_file_target(document.fullpath, host, name, need)
}

// Keeps a file of the index that is not on disk, for the collections of the other targets. A file on disk is found
// again from its directory.
note_unsaved_file :: proc(collection: ^SymbolCollection, file: ast.File) {
	if collection != &indexer.index.collection || os.exists(file.fullpath) {
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
		Unsaved_File{fullpath = strings.clone(forward, allocator), text = strings.clone(file.src, allocator)},
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
	key, value, just_inserted, _ := map_entry(&excluded.targets, fullpath)
	if just_inserted do key^ = strings.clone(fullpath, allocator)
	value^ = entry
	return
}

// The target that builds fullpath when the host does not. A lookup asks once per identifier, so the answer is kept
// until a reindex or removal of the file, a parse of its document, or a change of the host.
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

// Collects the files of pkg that target builds, as try_build_package collects those of the host.
@(private = "file")
build_target_package :: proc(index: ^Target_Index, target: parser.Build_Target, pkg: string) {
	index.built[get_index_unique_string(&index.collection, pkg)] = true
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
		collect_target_file(index, file.fullpath, file.text)
		runtime.arena_free_all(&arena)
	}
	matches, _ := filepath.glob(fmt.tprintf("%v/*.odin", pkg), context.temp_allocator)
	for fullpath in matches {
		// host_target is target here, so this skips the names of other platforms.
		if skip_file(filepath.base(fullpath)) do continue
		if data, err := os.read_entire_file(fullpath, context.allocator); err == nil {
			collect_target_file(index, fullpath, string(data))
		}
		runtime.arena_free_all(&arena)
	}
}

@(private = "file")
collect_target_file :: proc(index: ^Target_Index, fullpath, text: string) {
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
		collect_symbols(&index.collection, file, common.create_uri(fullpath, context.allocator).uri)
	}
}
