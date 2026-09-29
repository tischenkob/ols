package common

import "base:runtime"
import "core:os"
import "core:path/slashpath"
import "core:strings"
import "core:sync"

// Serializes child-process spawns across threads. A pipe end created on one thread can leak into a child
// that another thread forks or creates at the same moment, and a reader then waits for that child to exit.
// Hold it from pipe creation until the parent closes the child's pipe end, never across a wait.
@(private = "file")
process_spawn_mutex: sync.Mutex

process_spawn_lock :: proc() {
	sync.mutex_lock(&process_spawn_mutex)
}

process_spawn_unlock :: proc() {
	sync.mutex_unlock(&process_spawn_mutex)
}

// Decides which workspace paths a walk skips: git-ignored paths plus the user's exclude and include globs.
// Holds no thread-local state, so any thread may query it.
Workspace_Filter :: struct {
	// Workspace root with `/` separators and no trailing `/`.
	root:      string,
	// Root with symlinks resolved, the form os.walker reports, or empty when it cannot be resolved.
	real_root: string,
	// Git-ignored paths relative to root, without trailing `/`.
	ignored:   map[string]struct{},
	exclude:   []string,
	include:   []string,
	allocator: runtime.Allocator,
}

// Builds a filter for one workspace root. Owns copies of everything it stores; free it with `workspace_filter_destroy`.
workspace_filter_make :: proc(root: string, cfg: ^Config, allocator := context.allocator) -> Workspace_Filter {
	context.allocator = allocator
	f := Workspace_Filter {
		root      = normalize_filter_path(root),
		ignored   = make(map[string]struct{}),
		allocator = allocator,
	}
	if absolute, err := os.get_absolute_path(root, allocator); err == nil {
		f.real_root = normalize_filter_path(absolute)
		delete(absolute)
	}
	f.exclude = clone_string_list(cfg.workspace_exclude)
	f.include = clone_string_list(cfg.workspace_include)

	if cfg.enable_workspace_gitignore {
		collect_git_ignored(&f, root)
	}
	return f
}

workspace_filter_destroy :: proc(f: ^Workspace_Filter) {
	context.allocator = f.allocator
	delete(f.root)
	delete(f.real_root)
	for key in f.ignored {
		delete(key)
	}
	delete(f.ignored)
	for s in f.exclude {
		delete(s)
	}
	delete(f.exclude)
	for s in f.include {
		delete(s)
	}
	delete(f.include)
	f^ = {}
}

workspace_filter_skip_dir :: proc(f: ^Workspace_Filter, fullpath: string) -> bool {
	return filter_skip(f, fullpath, true)
}

workspace_filter_skip_file :: proc(f: ^Workspace_Filter, fullpath: string) -> bool {
	return filter_skip(f, fullpath, false)
}

// Matches a `/`-separated path relative to a workspace root.
// `*`, `?` and `[...]` match within one segment and `**` spans zero or more segments.
// A pattern without `/` matches the base name at any depth, and a leading `/` anchors it to the root.
glob_match :: proc(pattern, rel_path: string) -> bool {
	pattern, anchored := normalize_pattern(pattern)
	if !anchored {
		_, name := slashpath.split(rel_path)
		return match_segments(pattern, name)
	}
	return match_segments(pattern, rel_path)
}

// Reports whether some descendant of rel_dir could match the pattern.
glob_may_match_below :: proc(pattern, rel_dir: string) -> bool {
	pattern, anchored := normalize_pattern(pattern)
	if !anchored {
		return true
	}
	return match_prefix(pattern, rel_dir)
}

@(private = "file")
filter_skip :: proc(f: ^Workspace_Filter, fullpath: string, is_dir: bool) -> bool {
	if f == nil {
		return false
	}
	when ODIN_OS == .Windows {
		if strings.contains_rune(fullpath, '\\') {
			normalized, _ := strings.replace_all(fullpath, "\\", "/")
			defer delete(normalized)
			return filter_skip_rel(f, normalized, is_dir)
		}
	}
	return filter_skip_rel(f, fullpath, is_dir)
}

@(private = "file")
filter_skip_rel :: proc(f: ^Workspace_Filter, fullpath: string, is_dir: bool) -> bool {
	path := strings.trim_right(fullpath, "/")
	rel, inside := relative_to_root(f.root, path)
	if !inside && f.real_root != "" {
		rel, inside = relative_to_root(f.real_root, path)
	}
	if !inside || rel == "" {
		return false
	}
	if any_ancestor_matches(f.exclude, rel) {
		return true
	}
	if !is_git_ignored(f, rel) || any_ancestor_matches(f.include, rel) {
		return false
	}
	if is_dir {
		for pattern in f.include {
			if glob_may_match_below(pattern, rel) {
				return false
			}
		}
	}
	return true
}

@(private = "file")
relative_to_root :: proc(root, fullpath: string) -> (rel: string, inside: bool) {
	if fullpath == root {
		return "", true
	}
	if len(fullpath) > len(root) && strings.has_prefix(fullpath, root) && fullpath[len(root)] == '/' {
		return fullpath[len(root) + 1:], true
	}
	return "", false
}

// Reports whether rel or any of its ancestors matches one of the patterns.
@(private = "file")
any_ancestor_matches :: proc(patterns: []string, rel: string) -> bool {
	path := rel
	for path != "" {
		for pattern in patterns {
			if glob_match(pattern, path) {
				return true
			}
		}
		path = parent_path(path)
	}
	return false
}

@(private = "file")
is_git_ignored :: proc(f: ^Workspace_Filter, rel: string) -> bool {
	path := rel
	for path != "" {
		if path in f.ignored {
			return true
		}
		path = parent_path(path)
	}
	return false
}

@(private = "file")
parent_path :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[:max(i, 0)]
}

// Strips a trailing `/` and a leading `/`. A pattern is anchored when it contains `/` other than at its end.
@(private = "file")
normalize_pattern :: proc(pattern: string) -> (normalized: string, anchored: bool) {
	normalized = strings.trim_right(pattern, "/")
	anchored = strings.contains_rune(normalized, '/')
	normalized = strings.trim_left(normalized, "/")
	return
}

@(private = "file")
next_segment :: proc(s: string) -> (segment, rest: string) {
	if i := strings.index_byte(s, '/'); i >= 0 {
		return s[:i], s[i + 1:]
	}
	return s, ""
}

@(private = "file")
match_segments :: proc(pattern, path: string) -> bool {
	if pattern == "" {
		return path == ""
	}
	segment, rest := next_segment(pattern)
	if segment == "**" {
		remaining := path
		for {
			if match_segments(rest, remaining) {
				return true
			}
			if remaining == "" {
				return false
			}
			_, remaining = next_segment(remaining)
		}
	}
	if path == "" {
		return false
	}
	name, path_rest := next_segment(path)
	matched, err := slashpath.match(segment, name)
	return err == nil && matched && match_segments(rest, path_rest)
}

// Reports whether dir matches a proper prefix of the pattern, so a deeper path may match the rest.
@(private = "file")
match_prefix :: proc(pattern, dir: string) -> bool {
	if pattern == "" {
		return false
	}
	segment, rest := next_segment(pattern)
	if segment == "**" {
		return true
	}
	if dir == "" {
		return true
	}
	name, dir_rest := next_segment(dir)
	matched, err := slashpath.match(segment, name)
	return err == nil && matched && match_prefix(rest, dir_rest)
}

@(private = "file")
normalize_filter_path :: proc(path: string) -> string {
	result := strings.clone(strings.trim_right(path, "/\\"))
	when ODIN_OS == .Windows {
		for &c in transmute([]u8)result {
			if c == '\\' {
				c = '/'
			}
		}
	}
	return result
}

// Deep-copies a list of strings, so the copy outlives the memory the list came from.
clone_string_list :: proc(list: []string, allocator := context.allocator) -> []string {
	result := make([]string, len(list), allocator)
	for s, i in list {
		result[i] = strings.clone(s, allocator)
	}
	return result
}

// Fills the ignored set from git. A missing git, a failed run or a root outside a repository leaves it empty.
// A root that git ignores itself, listed as `./`, also leaves it empty: git would report nothing below it.
@(private = "file")
collect_git_ignored :: proc(f: ^Workspace_Filter, root: string) {
	// A repository-controlled core.fsmonitor would run an arbitrary command, so override it.
	command := []string {
		"git",
		"-c",
		"core.fsmonitor=false",
		"-C",
		root,
		"ls-files",
		"-z",
		"--others",
		"--ignored",
		"--exclude-standard",
		"--directory",
	}
	// process_exec creates its pipes and waits inside one call, so the lock spans it. git ls-files is short.
	process_spawn_lock()
	state, stdout, stderr, err := os.process_exec({command = command}, f.allocator)
	process_spawn_unlock()
	defer delete(stdout, f.allocator)
	defer delete(stderr, f.allocator)
	if err != nil || !state.success || state.exit_code != 0 {
		return
	}

	output := string(stdout)
	for entry in strings.split_iterator(&output, "\x00") {
		path := strings.trim_right(entry, "/")
		if path == "." {
			for key in f.ignored {
				delete(key, f.allocator)
			}
			clear(&f.ignored)
			return
		}
		if path != "" && path not_in f.ignored {
			f.ignored[strings.clone(path, f.allocator)] = {}
		}
	}
}
