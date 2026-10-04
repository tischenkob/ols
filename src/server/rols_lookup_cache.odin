package server

import "base:runtime"
import "core:strings"

import "src:common"

// The package and uri of the file a lookup runs for. A whole-file resolve looks up thousands of names
// for one file, and each call used to rebuild both strings in temp memory (the document cache arena there).
// The strings live on the heap and the last file is replaced, not freed, when another file asks.
LookupFileInfo :: struct {
	file, pkg, uri: string,
}

@(thread_local)
last_lookup_file: LookupFileInfo

lookup_file_info :: proc(current_file: string) -> (pkg: string, uri: string) {
	if current_file != last_lookup_file.file || last_lookup_file.uri == "" {
		heap := runtime.heap_allocator()
		delete(last_lookup_file.file, heap)
		delete(last_lookup_file.pkg, heap)
		delete(last_lookup_file.uri, heap)
		last_lookup_file = {
			file = strings.clone(current_file, heap),
			pkg  = strings.clone(get_package_from_filepath(current_file), heap),
			uri  = strings.clone(common.create_uri(current_file, context.temp_allocator).uri, heap),
		}
	}
	return last_lookup_file.pkg, last_lookup_file.uri
}
