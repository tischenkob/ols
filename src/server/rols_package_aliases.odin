#+private file
package server

import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:common"

// The workspace folders of one alias walk. Each folder builds its filter, which runs git, on first use only,
// so a folder that no collection overlaps costs nothing.
@(private = "package")
Package_Alias_Filters :: struct {
	config:  ^common.Config,
	folders: [dynamic]Alias_Folder,
}

Alias_Folder :: struct {
	path:      string,
	// The folder with an absolute path, the form the filter also compares, or empty when it cannot be resolved.
	real_path: string,
	filter:    Maybe(common.Workspace_Filter),
}

@(private = "package")
package_alias_filters :: proc(config: ^common.Config) -> Package_Alias_Filters {
	result := Package_Alias_Filters {
		config  = config,
		folders = make([dynamic]Alias_Folder, 0, len(config.workspace_folders), context.temp_allocator),
	}
	for workspace in config.workspace_folders {
		if uri, ok := common.parse_uri(workspace.uri, context.temp_allocator); ok {
			folder := Alias_Folder {
				path = normalize_alias_path(uri.path),
			}
			if absolute, err := os.get_absolute_path(uri.path, context.temp_allocator); err == nil {
				folder.real_path = normalize_alias_path(absolute)
			}
			append(&result.folders, folder)
		}
	}
	return result
}

// Returns the filter of the workspace folder that contains the collection root or lies inside it.
// A collection outside every workspace folder, such as core or vendor, gets no filter.
@(private = "package")
package_alias_filter_for :: proc(filters: ^Package_Alias_Filters, collection: string) -> ^common.Workspace_Filter {
	collection := normalize_alias_path(collection)
	for &folder in filters.folders {
		if !overlaps(collection, folder.path) && !overlaps(collection, folder.real_path) {
			continue
		}
		if folder.filter == nil {
			folder.filter = common.workspace_filter_make(folder.path, filters.config, context.temp_allocator)
		}
		return &folder.filter.?
	}
	return nil
}

overlaps :: proc(collection, root: string) -> bool {
	return root != "" && (path_within(collection, root) || path_within(root, collection))
}

// Reports whether path equals root or lies below it.
path_within :: proc(path, root: string) -> bool {
	return path == root || (strings.has_prefix(path, root) && len(path) > len(root) && path[len(root)] == '/')
}

normalize_alias_path :: proc(path: string) -> string {
	result := strings.trim_right(path, "/\\")
	when ODIN_OS == .Windows {
		result, _ = strings.replace_all(result, "\\", "/", context.temp_allocator)
	}
	return result
}

// Reports whether name, a directory listed for the import path typed after "collection:", is a package the alias
// walk kept or a parent of one. The walk already skipped git-ignored, excluded and hidden paths, so import path
// completion reuses its result. Paths come from the typed text because the listing may resolve symlinks.
// A collection without aliases keeps every directory.
@(private = "package")
collection_dir_has_package :: proc(collection, typed, name: string) -> bool {
	aliases, ok := build_cache.pkg_aliases[collection]
	if !ok {
		return true
	}
	rel, _ := filepath.join({filepath.dir(typed), name}, context.temp_allocator)
	rel, _ = filepath.replace_separators(rel, '/', context.temp_allocator)
	for alias in aliases {
		if path_within(alias, rel) {
			return true
		}
	}
	return false
}
