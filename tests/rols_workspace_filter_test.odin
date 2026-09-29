package tests

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

import "src:common"
import "src:server"

@(test)
workspace_glob_match :: proc(t: ^testing.T) {
	Case :: struct {
		pattern: string,
		path:    string,
		want:    bool,
	}
	cases := []Case {
		{"**/gen", "gen", true},
		{"**/gen", "a/b/gen", true},
		{"**/gen", "a/gen/b", false},
		{"src/**/test.odin", "src/test.odin", true},
		{"src/**/test.odin", "src/a/b/test.odin", true},
		{"src/**/test.odin", "lib/a/test.odin", false},
		{"gen/**", "gen/a", true},
		{"gen/**", "gen/a/b.odin", true},
		{"gen/**", "other/a", false},
		{"build", "build", true},
		{"build", "a/b/build", true},
		{"build", "a/build/c", false},
		{"build", "builder", false},
		{"build/", "a/build", true},
		{"/build", "build", true},
		{"/build", "a/build", false},
		{"*.odin", "a/b/c.odin", true},
		{"*.odin", "a/b/c.txt", false},
		{"src/*.odin", "src/a.odin", true},
		{"src/*.odin", "src/a/b.odin", false},
		{"file?.odin", "x/file1.odin", true},
		{"file?.odin", "x/file12.odin", false},
		{"v[0-9]/x", "v3/x", true},
		{"v[0-9]/x", "vx/x", false},
		{"v[^0-9]/x", "vx/x", true},
		{"a/b", "a/b/c", false},
		{"a/b", "a", false},
	}
	for c in cases {
		testing.expectf(
			t,
			common.glob_match(c.pattern, c.path) == c.want,
			"glob_match(%q, %q) should be %v",
			c.pattern,
			c.path,
			c.want,
		)
	}
}

@(test)
workspace_glob_may_match_below :: proc(t: ^testing.T) {
	Case :: struct {
		pattern: string,
		dir:     string,
		want:    bool,
	}
	cases := []Case {
		{"gen/keep/**", "gen", true},
		{"gen/keep/**", "gen/keep", true},
		{"gen/keep/**", "gen/keep/deep", true},
		{"gen/keep/**", "gen/other", false},
		{"gen/keep", "gen", true},
		{"gen/keep", "gen/keep", false},
		{"/gen", "gen", false},
		{"**/x.odin", "a/b", true},
		{"src/*.odin", "src", true},
		{"src/*.odin", "src/a", false},
		{"s?c/[ab]/x", "src/a", true},
		{"s?c/[ab]/x", "src/c", false},
		{"build", "anything/at/all", true},
	}
	for c in cases {
		testing.expectf(
			t,
			common.glob_may_match_below(c.pattern, c.dir) == c.want,
			"glob_may_match_below(%q, %q) should be %v",
			c.pattern,
			c.dir,
			c.want,
		)
	}
}

@(test)
workspace_filter_without_git :: proc(t: ^testing.T) {
	cfg := common.Config {
		workspace_exclude = {"build", "vendor/**"},
		workspace_include = {"build/keep"},
	}
	filter := common.workspace_filter_make("/ws/", &cfg)
	defer common.workspace_filter_destroy(&filter)

	testing.expect(t, common.workspace_filter_skip_dir(&filter, "/ws/build"))
	testing.expect(t, common.workspace_filter_skip_dir(&filter, "/ws/a/build"))
	testing.expect(t, common.workspace_filter_skip_file(&filter, "/ws/build/keep/a.odin"))
	testing.expect(t, common.workspace_filter_skip_file(&filter, "/ws/vendor/x/y.odin"))
	testing.expect(t, !common.workspace_filter_skip_dir(&filter, "/ws"))
	testing.expect(t, !common.workspace_filter_skip_dir(&filter, "/ws/src"))
	testing.expect(t, !common.workspace_filter_skip_file(&filter, "/ws/src/builder.odin"))
	testing.expect(t, !common.workspace_filter_skip_dir(&filter, "/other/build"))
	testing.expect(t, !common.workspace_filter_skip_dir(&filter, "/wsx/build"))
	testing.expect(t, !common.workspace_filter_skip_dir(nil, "/ws/build"))
}

@(test)
workspace_filter_gitignore :: proc(t: ^testing.T) {
	if !run_git(".", "--version") {
		log.info("git is not on PATH, skipping workspace_filter_gitignore")
		return
	}

	root, err := os.make_directory_temp("", "ols-ws-filter-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to create temporary directory: %v", err) {
		return
	}
	defer os.remove_all(root)
	root, err = os.get_absolute_path(root, context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to resolve temporary directory: %v", err) {
		return
	}
	if !testing.expect(t, run_git(root, "init", "-q")) {
		return
	}

	join :: proc(elems: ..string) -> string {
		joined, _ := filepath.join(elems, context.temp_allocator)
		return joined
	}
	gen := join(root, "gen")
	keep := join(root, "gen", "keep")
	other := join(root, "gen", "other")
	src := join(root, "src")
	for dir in ([]string{gen, keep, other, src}) {
		if !testing.expect(t, os.make_directory(dir) == nil) {
			return
		}
	}
	files := [][2]string {
		{join(root, ".gitignore"), "gen/\n"},
		{join(keep, "a.odin"), "package keep"},
		{join(other, "b.odin"), "package other"},
		{join(src, "c.odin"), "package src"},
	}
	for file in files {
		if !testing.expect(t, os.write_entire_file(file[0], file[1]) == nil) {
			return
		}
	}

	{
		cfg := common.Config {
			enable_workspace_gitignore = true,
		}
		filter := common.workspace_filter_make(root, &cfg)
		defer common.workspace_filter_destroy(&filter)
		testing.expect(t, common.workspace_filter_skip_dir(&filter, gen))
		testing.expect(t, common.workspace_filter_skip_file(&filter, join(keep, "a.odin")))
		testing.expect(t, !common.workspace_filter_skip_dir(&filter, src))
		testing.expect(t, !common.workspace_filter_skip_file(&filter, join(src, "c.odin")))
	}

	{
		cfg := common.Config {
			enable_workspace_gitignore = true,
			workspace_include          = {"gen/keep/**"},
		}
		filter := common.workspace_filter_make(root, &cfg)
		defer common.workspace_filter_destroy(&filter)
		testing.expect(t, !common.workspace_filter_skip_dir(&filter, gen))
		testing.expect(t, !common.workspace_filter_skip_dir(&filter, keep))
		testing.expect(t, common.workspace_filter_skip_dir(&filter, other))
		testing.expect(t, !common.workspace_filter_skip_file(&filter, join(keep, "a.odin")))
		testing.expect(t, common.workspace_filter_skip_file(&filter, join(other, "b.odin")))
	}

	{
		cfg := common.Config {
			enable_workspace_gitignore = true,
			workspace_include          = {"gen/keep/**"},
			workspace_exclude          = {"gen/keep/a.odin"},
		}
		filter := common.workspace_filter_make(root, &cfg)
		defer common.workspace_filter_destroy(&filter)
		testing.expect(t, common.workspace_filter_skip_file(&filter, join(keep, "a.odin")))
	}

	{
		cfg := common.Config {
			enable_workspace_gitignore = false,
		}
		filter := common.workspace_filter_make(root, &cfg)
		defer common.workspace_filter_destroy(&filter)
		testing.expect(t, !common.workspace_filter_skip_dir(&filter, gen))
		testing.expect(t, !common.workspace_filter_skip_file(&filter, join(other, "b.odin")))
	}
}

@(test)
workspace_filter_append_packages :: proc(t: ^testing.T) {
	if !run_git(".", "--version") {
		log.info("git is not on PATH, skipping workspace_filter_append_packages")
		return
	}

	root, err := os.make_directory_temp("", "ols-ws-packages-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to create temporary directory: %v", err) {
		return
	}
	defer os.remove_all(root)
	root, err = os.get_absolute_path(root, context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to resolve temporary directory: %v", err) {
		return
	}
	if !testing.expect(t, run_git(root, "init", "-q")) {
		return
	}

	join :: proc(elems: ..string) -> string {
		joined, _ := filepath.join(elems, context.temp_allocator)
		return joined
	}
	a := join(root, "a")
	gen := join(root, "gen")
	gen_x := join(root, "gen", "x")
	for dir in ([]string{a, gen, gen_x}) {
		if !testing.expect(t, os.make_directory(dir) == nil) {
			return
		}
	}
	files := [][2]string {
		{join(root, ".gitignore"), "gen/\n"},
		{join(a, "a.odin"), "package a"},
		{join(gen_x, "x.odin"), "package x"},
	}
	for file in files {
		if !testing.expect(t, os.write_entire_file(file[0], file[1]) == nil) {
			return
		}
	}

	packages_with :: proc(root: string, cfg: common.Config) -> []string {
		cfg := cfg
		filter := common.workspace_filter_make(root, &cfg, context.temp_allocator)
		packages := make([dynamic]string, context.temp_allocator)
		server.append_packages(root, &packages, {}, context.temp_allocator, filter = &filter)
		slice.sort(packages[:])
		return packages[:]
	}

	packages := packages_with(root, {enable_workspace_gitignore = true})
	testing.expectf(t, slice.equal(packages, []string{a}), "%v", packages)

	packages = packages_with(root, {enable_workspace_gitignore = true, workspace_include = {"gen/x/**"}})
	testing.expectf(t, slice.equal(packages, []string{a, gen_x}), "%v", packages)

	packages = packages_with(root, {enable_workspace_gitignore = false, workspace_exclude = {"a"}})
	testing.expectf(t, slice.equal(packages, []string{gen_x}), "%v", packages)

	// The walker reports paths under the resolved root, so a symlinked root must still filter.
	link := strings.concatenate({root, "-link"}, context.temp_allocator)
	if os.symlink(root, link) != nil {
		log.info("cannot create a symlink, skipping the symlinked root check")
		return
	}
	defer os.remove(link)
	packages = packages_with(link, {enable_workspace_gitignore = true})
	testing.expectf(t, slice.equal(packages, []string{a}), "%v", packages)
}

// A workspace root that its parent repository ignores keeps every path: git lists only `./` for it.
@(test)
workspace_filter_ignored_root :: proc(t: ^testing.T) {
	if !run_git(".", "--version") {
		log.info("git is not on PATH, skipping workspace_filter_ignored_root")
		return
	}

	parent, err := os.make_directory_temp("", "ols-ws-parent-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to create temporary directory: %v", err) {
		return
	}
	defer os.remove_all(parent)
	parent, err = os.get_absolute_path(parent, context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to resolve temporary directory: %v", err) {
		return
	}
	if !testing.expect(t, run_git(parent, "init", "-q")) {
		return
	}

	join :: proc(elems: ..string) -> string {
		joined, _ := filepath.join(elems, context.temp_allocator)
		return joined
	}
	root := join(parent, "ws")
	a := join(root, "a")
	for dir in ([]string{root, a}) {
		if !testing.expect(t, os.make_directory(dir) == nil) {
			return
		}
	}
	files := [][2]string{{join(parent, ".gitignore"), "ws/\n"}, {join(a, "a.odin"), "package a"}}
	for file in files {
		if !testing.expect(t, os.write_entire_file(file[0], file[1]) == nil) {
			return
		}
	}

	cfg := common.Config {
		enable_workspace_gitignore = true,
	}
	filter := common.workspace_filter_make(root, &cfg)
	defer common.workspace_filter_destroy(&filter)
	testing.expect_value(t, len(filter.ignored), 0)
	testing.expect(t, !common.workspace_filter_skip_dir(&filter, a))
	testing.expect(t, !common.workspace_filter_skip_file(&filter, join(a, "a.odin")))
}

@(private = "file")
run_git :: proc(dir: string, args: ..string) -> bool {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "git", "-C", dir)
	append(&command, ..args)
	common.process_spawn_lock()
	state, _, _, err := os.process_exec({command = command[:]}, context.temp_allocator)
	common.process_spawn_unlock()
	return err == nil && state.success && state.exit_code == 0
}
