#+feature dynamic-literals
package server

import "base:runtime"
import "core:slice"

import "core:fmt"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "src:common"
import "src:spall"

os_enum_to_string: [runtime.Odin_OS_Type]string = {
	.Windows      = "windows",
	.Darwin       = "darwin",
	.Linux        = "linux",
	.FreeBSD      = "freebsd",
	.WASI         = "wasi",
	.JS           = "js",
	.Freestanding = "freestanding",
	.OpenBSD      = "openbsd",
	.NetBSD       = "netbsd",
	.Orca         = "orca",
	.Unknown      = "unknown",
}

os_string_to_enum: map[string]runtime.Odin_OS_Type = {
	"Windows"      = .Windows,
	"windows"      = .Windows,
	"Darwin"       = .Darwin,
	"darwin"       = .Darwin,
	"Linux"        = .Linux,
	"linux"        = .Linux,
	"Freebsd"      = .FreeBSD,
	"freebsd"      = .FreeBSD,
	"FreeBSD"      = .FreeBSD,
	"Wasi"         = .WASI,
	"wasi"         = .WASI,
	"WASI"         = .WASI,
	"Js"           = .JS,
	"js"           = .JS,
	"JS"           = .JS,
	"Freestanding" = .Freestanding,
	"freestanding" = .Freestanding,
	"Wasm"         = .JS,
	"wasm"         = .JS,
	"Openbsd"      = .OpenBSD,
	"openbsd"      = .OpenBSD,
	"OpenBSD"      = .OpenBSD,
	"Netbsd"       = .NetBSD,
	"netbsd"       = .NetBSD,
	"NetBSD"       = .NetBSD,
	"Orca"         = .Orca,
	"orca"         = .Orca,
	"Unknown"      = .Unknown,
	"unknown"      = .Unknown,
}

// rols: the platform odin builds for, from set_when_target, else the profile, falling back to the host.
host_target :: proc() -> parser.Build_Target {
	if target, ok := when_target.?; ok do return target
	arch := common.config.profile.arch
	return {
		os = os_string_to_enum[common.config.profile.os] or_else ODIN_OS,
		arch = parser.get_build_arch_from_string(arch) if arch != "" else ODIN_ARCH,
	}
}

// rols: the OS and architecture a file name asks for, `.Unknown` for none, like is_excluded_target_filename in odin's
// build_settings.cpp. Only these names count: `_unix` and `_bsd` are ordinary names that odin always builds.
file_name_target :: proc(filename: string) -> (target: parser.Build_Target, hidden: bool) {
	name := filename
	if dot := strings.last_index(name, "."); dot >= 0 do name = name[:dot]
	if strings.has_prefix(name, ".") do return {}, true

	last := strings.last_index(name, "_")
	if last < 0 do return
	str1 := name[last + 1:]
	str2 := name[:last]
	str2 = str2[strings.last_index(str2, "_") + 1:]

	os1, _ := parser.get_build_os_from_string(str1)
	os2, _ := parser.get_build_os_from_string(str2)
	arch1 := parser.get_build_arch_from_string(str1)
	arch2 := parser.get_build_arch_from_string(str2)

	if os1 != .Unknown {
		target.os, target.arch = os1, arch2
	} else if arch1 != .Unknown {
		target.os, target.arch = os2, arch1
	}
	return
}

skip_file :: proc(filename: string) -> bool {
	target, hidden := file_name_target(filename)
	host := host_target()
	return hidden || (target.os != .Unknown && target.os != host.os) || (target.arch != .Unknown && target.arch != host.arch)
}

// Finds all packages under the provided path by walking the file system
// and appends them to the provided dynamic array
append_packages :: proc(
	path: string,
	pkgs: ^[dynamic]string,
	skip: map[string]struct{},
	allocator := context.temp_allocator,
	skip_hidden := false,
	// rols: filter skips git-ignored and excluded paths
	filter: ^common.Workspace_Filter = nil,
) {
	if path in skip {
		return
	}

	w := os.walker_create(path)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if info.type == .Directory {
			if info.fullpath in skip || (skip_hidden && strings.has_prefix(info.name, ".")) {
				os.walker_skip_dir(&w)
			}
			// rols: skip filtered directories
			if common.workspace_filter_skip_dir(filter, info.fullpath) {
				os.walker_skip_dir(&w)
			}
			continue
		}

		if filepath.ext(info.name) == ".odin" {
			// rols: skip filtered files
			if common.workspace_filter_skip_file(filter, info.fullpath) {
				continue
			}
			dir := filepath.dir(info.fullpath)
			if !slice.contains(pkgs[:], dir) {
				append(pkgs, strings.clone(dir, allocator))
			}
		}
	}
}

should_collect_file :: proc(file_tags: parser.File_Tags) -> bool {
	// rols: match os and arch groups like odin does, including multiple `#+build` lines and negations.
	return parser.match_build_tags(file_tags, host_target())
}

try_build_package :: proc(pkg_name: string) {
	spall.trace(#procedure, pkg_name)

	if pkg, ok := build_cache.loaded_pkgs[pkg_name]; ok {
		return
	}
	defer clear_index_cache()
	// rols: the index holds the host's declarations, also when a lint evaluates `when` for another target.
	saved_eval_target := when_eval_target
	when_eval_target = nil
	defer when_eval_target = saved_eval_target

	spall.trace(#procedure, pkg_name)

	matches, err := filepath.glob(fmt.tprintf("%v/*.odin", pkg_name), context.temp_allocator)

	if err != nil && err != .Not_Exist {
		log.errorf("Failed to glob %v for indexing package: %v", pkg_name, err)
		return
	}

	arena: runtime.Arena
	result := runtime.arena_init(&arena, mem.Megabyte * 40, context.allocator)
	defer runtime.arena_destroy(&arena)

	{
		context.allocator = runtime.arena_allocator(&arena)

		for fullpath in matches {
			if skip_file(filepath.base(fullpath)) {
				continue
			}

			data, err := os.read_entire_file(fullpath, context.allocator)

			if err != nil {
				log.errorf("failed to read entire file for indexing %v: %v", fullpath, err)
				continue
			}

			p := parser.Parser {
				flags = {.Optional_Semicolons},
			}
			if !is_ols_builtin_file(fullpath) {
				p.err = log_error_handler
				p.warn = log_warning_handler
			}

			dir := filepath.base(filepath.dir(fullpath))

			pkg := new(ast.Package)
			pkg.kind = .Normal
			pkg.fullpath = fullpath
			pkg.name = dir

			if dir == "runtime" || strings.contains(fullpath, "base/runtime") {
				pkg.kind = .Runtime
			}

			file := ast.File {
				fullpath = fullpath,
				src      = string(data),
				pkg      = pkg,
			}

			ok := parse_file(&p, &file)

			if !ok {
				if !is_ols_builtin_file(fullpath) {
					log.errorf("error in parse file for indexing %v", fullpath)
				}
				continue
			}

			uri := common.create_uri(fullpath, context.allocator)

			collect_symbols(&indexer.index.collection, file, uri.uri)

			runtime.arena_free_all(&arena)
		}
	}

	build_cache.loaded_pkgs[strings.clone(pkg_name, indexer.index.collection.allocator)] = PackageCacheInfo {
		timestamp = time.now(),
	}
}

remove_index_file :: proc(uri: common.Uri) -> common.Error {
	ok: bool
	defer clear_index_cache()

	fullpath := uri.path

	when ODIN_OS == .Windows {
		fullpath, _ = filepath.replace_separators(fullpath, '/', context.temp_allocator)
	}

	corrected_uri := common.create_uri(fullpath, context.temp_allocator)
	invalidate_document_symbol_caches()
	// rols: the other targets' declarations of the package are collected again
	forget_excluded_file(fullpath)

	for k, &v in indexer.index.collection.packages {
		for k2, v2 in v.symbols {
			if strings.equal_fold(corrected_uri.uri, v2.uri) {
				free_symbol(v2, indexer.index.collection.allocator)
				delete_key(&v.symbols, k2)
			}
		}

		for method, &symbols in v.methods {
			for i := len(symbols) - 1; i >= 0; i -= 1 {
				#no_bounds_check symbol := symbols[i]
				if strings.equal_fold(corrected_uri.uri, symbol.uri) {
					unordered_remove(&symbols, i)
				}
			}
		}
	}

	// rols: a fallback that the removed file's declaration hid takes its name back.
	forget_hidden_fallbacks(&indexer.index.collection, corrected_uri.uri, fold = true)
	restore_hidden_fallbacks(&indexer.index.collection)

	return .None
}

index_file :: proc(uri: common.Uri, text: string) -> common.Error {
	ok: bool
	defer clear_index_cache()

	spall.trace(#procedure, uri.path)

	fullpath := uri.path

	p := parser.Parser {
		flags = {.Optional_Semicolons},
	}
	if !is_ols_builtin_file(fullpath) {
		p.err = log_error_handler
		p.warn = log_warning_handler
	}

	when ODIN_OS == .Windows {
		correct := common.get_case_sensitive_path(fullpath, context.temp_allocator)
		fullpath, _ = filepath.replace_separators(correct, '/', context.temp_allocator)
	}

	dir := filepath.base(filepath.dir(fullpath))

	// rols: the package only lives for this reindex
	pkg := new(ast.Package, context.temp_allocator)
	pkg.kind = .Normal
	pkg.fullpath = fullpath
	pkg.name = dir

	if dir == "runtime" || strings.contains(fullpath, "base/runtime") {
		pkg.kind = .Runtime
	}

	file := ast.File {
		fullpath = fullpath,
		src      = text,
		pkg      = pkg,
	}

	if !parse_file(&p, &file, context.temp_allocator) || file.syntax_error_count > 0 {
		if !is_ols_builtin_file(fullpath) {
			log.errorf("error in parse file for indexing %v", fullpath)
		}
		return .None
	}

	corrected_uri := common.create_uri(fullpath, context.temp_allocator)
	invalidate_document_symbol_caches()
	// rols: the other targets' declarations of the package are collected again
	forget_excluded_file(fullpath)

	for k, &v in indexer.index.collection.packages {
		for k2, v2 in v.symbols {
			if corrected_uri.uri == v2.uri {
				free_symbol(v2, indexer.index.collection.allocator)
				delete_key(&v.symbols, k2)
			}
		}

		for method, &symbols in v.methods {
			for i := len(symbols) - 1; i >= 0; i -= 1 {
				#no_bounds_check symbol := symbols[i]
				if corrected_uri.uri == symbol.uri {
					unordered_remove(&symbols, i)
				}
			}
		}
	}

	// rols: the file's own hidden fallbacks are collected again.
	forget_hidden_fallbacks(&indexer.index.collection, corrected_uri.uri)
	if ret := collect_symbols(&indexer.index.collection, file, corrected_uri.uri); ret != .None {
		log.errorf("failed to collect symbols on save %v", ret)
	}
	// rols: a fallback whose name the file no longer declares takes the name back.
	restore_hidden_fallbacks(&indexer.index.collection)

	return .None
}


setup_index :: proc(builtin_path: string) {
	build_cache.loaded_pkgs = make(map[string]PackageCacheInfo, 50)
	symbol_collection := make_symbol_collection(&common.config)
	indexer.index = make_memory_index(symbol_collection)

	try_build_package(builtin_path)
}

free_index :: proc() {
	spall.trace(#procedure)

	for k in build_cache.loaded_pkgs {
		delete(k, indexer.index.collection.allocator)
	}
	delete(build_cache.loaded_pkgs)
	delete_symbol_collection(indexer.index.collection)
	// rols: the index of the files that the host does not build goes with it
	free_excluded()
	memory_index_clear_cache(&indexer.index)
	build_cache.pkg_aliases = {}
}

log_error_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	log.warnf("%v %v %v", pos, msg, args)
}

log_warning_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	log.warnf("%v %v %v", pos, msg, args)
}
