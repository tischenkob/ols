package server

import "src:common"

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

BuildCache :: struct {
	loaded_pkgs: map[string]PackageCacheInfo,
	pkg_aliases: map[string][dynamic]string,
}

PackageCacheInfo :: struct {
	timestamp: time.Time,
}

@(thread_local)
build_cache: BuildCache


clear_all_package_aliases :: proc() {
	for collection_name, alias_array in build_cache.pkg_aliases {
		for alias in alias_array {
			delete(alias)
		}
		delete(alias_array)
	}

	clear(&build_cache.pkg_aliases)
}

//Go through all the collections to find all the possible packages that exists
find_all_package_aliases :: proc(config: ^common.Config) {
	// rols: skip git-ignored and excluded paths, one filter per workspace root
	filters := package_alias_filters(config)
	for k, v in config.collections {
		pkgs := make([dynamic]string, context.temp_allocator)
		append_packages(
			v,
			&pkgs,
			{},
			context.temp_allocator,
			skip_hidden = config.enable_auto_import_skip_hidden_paths,
			// rols: walk with the filter of the overlapping workspace root
			filter = package_alias_filter_for(filters, v),
		)

		for pkg in pkgs {
			if pkg, err := filepath.rel(v, pkg, context.temp_allocator); err == .None {
				forward_pkg, _ := filepath.replace_separators(pkg, '/', context.temp_allocator)
				if k not_in build_cache.pkg_aliases {
					build_cache.pkg_aliases[k] = make([dynamic]string)
				}

				aliases := &build_cache.pkg_aliases[k]

				append(aliases, strings.clone(forward_pkg))
			}
		}
	}
}

refresh_package_aliases_if_hidden_paths_changed :: proc(
	previous_value: bool,
	config: ^common.Config,
) -> bool {
	if previous_value == config.enable_auto_import_skip_hidden_paths {
		return false
	}

	clear_all_package_aliases()
	find_all_package_aliases(config)

	return true
}
