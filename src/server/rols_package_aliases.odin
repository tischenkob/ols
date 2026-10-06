#+private file
package server

import "core:strings"

import "src:common"

// Builds one workspace filter per workspace folder, so the alias walk spawns git once per root.
@(private = "package")
package_alias_filters :: proc(
	config: ^common.Config,
	allocator := context.temp_allocator,
) -> []common.Workspace_Filter {
	filters := make([dynamic]common.Workspace_Filter, 0, len(config.workspace_folders), allocator)
	for workspace in config.workspace_folders {
		if uri, ok := common.parse_uri(workspace.uri, context.temp_allocator); ok {
			append(&filters, common.workspace_filter_make(uri.path, config, allocator))
		}
	}
	return filters[:]
}

// Returns the filter of the workspace folder that contains the collection root or lies inside it.
// A collection outside every workspace folder, such as core or vendor, gets no filter.
@(private = "package")
package_alias_filter_for :: proc(filters: []common.Workspace_Filter, collection: string) -> ^common.Workspace_Filter {
	collection := normalize_alias_path(collection)
	for &filter in filters {
		for root in ([]string{filter.root, filter.real_root}) {
			if root != "" && (path_within(collection, root) || path_within(root, collection)) {
				return &filter
			}
		}
	}
	return nil
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
