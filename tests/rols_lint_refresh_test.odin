package tests

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"

import "src:common"
import "src:server"
import test "src:testing"

// Tests that store diagnostics in the global maps take turns, with the tests that seed a checker diagnostic, and
// free what they stored before the next one.
@(private = "package")
lock_global_diagnostics :: proc() {
	sync.lock(&test.seed_mutex)
}

@(private = "package")
unlock_global_diagnostics :: proc() {
	server.reset_diagnostics()
	sync.unlock(&test.seed_mutex)
}

@(private = "file")
Refresh_Package :: struct {
	config: common.Config,
	dir:    string,
}

@(private = "file")
A_TEXT :: "package p\n\nf :: proc(x: int) -> int { return 1 }\n"

@(private = "file")
B_REGISTERS :: "package p\n\nregister :: proc(h: proc(x: int) -> int) {}\n\ng :: proc() { register(f) }\n"

@(private = "file")
B_CALLS :: "package p\n\nregister :: proc(h: proc(x: int) -> int) {}\n\ng :: proc() { f(1) }\n"

@(private = "file")
B_UNRELATED :: "package p\n\nregister :: proc(h: proc(x: int) -> int) {}\n\ng :: proc() {}\n"

// Writes a.odin and b.odin into a temporary package directory, then opens both, a.odin first.
@(private = "file")
open_package :: proc(t: ^testing.T, pkg: ^Refresh_Package, b_text: string) -> bool {
	dir, err := os.make_directory_temp("", "ols-lint-refresh-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to create temporary directory: %v", err) do return false
	pkg.dir, err = os.get_absolute_path(dir, context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to resolve temporary directory: %v", err) do return false
	files := [][2]string{{"a.odin", A_TEXT}, {"b.odin", b_text}}
	for file in files {
		write_err := os.write_entire_file(file_path(pkg, file[0]), transmute([]u8)file[1])
		if !testing.expectf(t, write_err == nil, "failed to write %s: %v", file[0], write_err) do return false
	}
	for file in files {
		open_err := server.document_open(file_uri(pkg, file[0]), strings.clone(file[1]), &pkg.config, nil)
		if !testing.expectf(t, open_err == .None, "failed to open %s: %v", file[0], open_err) do return false
	}
	return true
}

@(private = "file")
file_path :: proc(pkg: ^Refresh_Package, name: string) -> string {
	path, _ := filepath.join({pkg.dir, name}, context.temp_allocator)
	return path
}

@(private = "file")
file_uri :: proc(pkg: ^Refresh_Package, name: string) -> string {
	return common.create_uri(file_path(pkg, name), context.temp_allocator).uri
}

@(private = "file")
change_b :: proc(t: ^testing.T, pkg: ^Refresh_Package, text: string) -> bool {
	params_text := fmt.tprintf(
		`{{"textDocument":{{"uri":"%s","version":2}},"contentChanges":[{{"text":%q}}]}}`,
		file_uri(pkg, "b.odin"),
		text,
	)
	params, parse_err := json.parse_string(params_text, parse_integers = true, allocator = context.temp_allocator)
	if !testing.expectf(t, parse_err == .None, "failed to parse didChange params: %v", parse_err) do return false
	change_err := server.notification_did_change(params, i64(0), &pkg.config, nil)
	return testing.expectf(t, change_err == .None, "didChange failed: %v", change_err)
}

@(private = "file")
unused_parameters_of_a :: proc(pkg: ^Refresh_Package) -> int {
	count := 0
	for d in server.diagnostics_of(.Lint, file_uri(pkg, "a.odin"), context.temp_allocator) {
		if d.code == "unused-parameter" do count += 1
	}
	return count
}

// Runs body over a package with the documents, the index and the global diagnostics of a server, and tears them
// down after.
@(private = "file")
with_package :: proc(t: ^testing.T, b_text: string, body: proc(t: ^testing.T, pkg: ^Refresh_Package)) {
	pkg := Refresh_Package {
		config = {
			enable_diagnostics = true,
			enable_lint_unused_parameter = true,
			collections = make(map[string]string),
		},
	}
	defer delete(pkg.config.collections)

	lock_global_diagnostics()
	defer unlock_global_diagnostics()

	server.document_storage.documents = make(map[string]server.Document)
	defer {
		server.document_storage_shutdown()
		server.document_storage = {}
	}
	builtin_path := server.get_builtin_path()
	defer delete(builtin_path)
	server.setup_index(builtin_path)
	defer server.free_index()

	if !open_package(t, &pkg, b_text) do return
	defer os.remove_all(pkg.dir)
	// A test may leave a file closed.
	defer for name in ([]string{"a.odin", "b.odin"}) {
		if server.document_storage.documents[file_path(&pkg, name)].client_owned do server.document_close(file_uri(&pkg, name))
	}
	body(t, &pkg)
}

@(test)
lint_refresh_unused_parameter_clears_when_sibling_uses_procedure :: proc(t: ^testing.T) {
	with_package(t, B_CALLS, proc(t: ^testing.T, pkg: ^Refresh_Package) {
		testing.expect_value(t, unused_parameters_of_a(pkg), 1)
		if !change_b(t, pkg, B_REGISTERS) do return
		testing.expect_value(t, unused_parameters_of_a(pkg), 0)
	})
}

@(test)
lint_refresh_unused_parameter_returns_when_sibling_drops_use :: proc(t: ^testing.T) {
	with_package(
		t,
		B_REGISTERS,
		proc(t: ^testing.T, pkg: ^Refresh_Package) {
			testing.expect_value(t, unused_parameters_of_a(pkg), 0)
			if !change_b(t, pkg, B_CALLS) do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)

			// b.odin no longer names f, so its edit cannot turn the verdict of a.odin, which keeps the diagnostics it
			// has, here none.
			server.remove_diagnostics(.Lint, file_uri(pkg, "a.odin"))
			if !change_b(t, pkg, B_UNRELATED) do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 0)
		},
	)
}

// A change to a file of another package that names the package and the procedure may add an importer's use, so it
// relints a.odin. The relint finds the use in d.odin, written to disk without a notification, which shows it ran.
@(test)
lint_refresh_importer_change_relints_package :: proc(t: ^testing.T) {
	with_package(
		t,
		B_UNRELATED,
		proc(t: ^testing.T, pkg: ^Refresh_Package) {
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)

			d_err := os.write_entire_file(file_path(pkg, "d.odin"), "package p\n\nd :: proc() { register(f) }\n")
			if !testing.expectf(t, d_err == nil, "failed to write d.odin: %v", d_err) do return
			q_dir := file_path(pkg, "q")
			if !testing.expect(t, os.make_directory(q_dir) == nil) do return
			c_path, _ := filepath.join({q_dir, "c.odin"}, context.temp_allocator)
			c_uri := common.create_uri(c_path, context.temp_allocator).uri
			c_text := "package q\n\nimport p \"..\"\n\nh :: proc() {}\n"
			open_err := server.document_open(c_uri, strings.clone(c_text), &pkg.config, nil)
			if !testing.expectf(t, open_err == .None, "failed to open c.odin: %v", open_err) do return
			defer server.document_close(c_uri)
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)

			params_text := fmt.tprintf(
				`{{"textDocument":{{"uri":"%s","version":2}},"contentChanges":[{{"text":%q}}]}}`,
				c_uri,
				"package q\n\nimport p \"..\"\n\nh :: proc() { p.register(p.f) }\n",
			)
			params, parse_err := json.parse_string(params_text, parse_integers = true, allocator = context.temp_allocator)
			if !testing.expectf(t, parse_err == .None, "failed to parse didChange params: %v", parse_err) do return
			change_err := server.notification_did_change(params, i64(0), &pkg.config, nil)
			if !testing.expectf(t, change_err == .None, "didChange failed: %v", change_err) do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 0)
		},
	)
}

@(test)
lint_refresh_open_does_not_relint_siblings :: proc(t: ^testing.T) {
	with_package(
		t,
		B_CALLS,
		proc(t: ^testing.T, pkg: ^Refresh_Package) {
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)

			// An open reads the same text from disk that the verdict of a.odin came from, so a.odin keeps the
			// diagnostics it has, here none.
			server.remove_diagnostics(.Lint, file_uri(pkg, "a.odin"))
			server.document_close(file_uri(pkg, "b.odin"))
			open_err := server.document_open(file_uri(pkg, "b.odin"), strings.clone(B_CALLS), &pkg.config, nil)
			testing.expectf(t, open_err == .None, "failed to reopen b.odin: %v", open_err)
			testing.expect_value(t, unused_parameters_of_a(pkg), 0)
		},
	)
}

// The tests run no checker thread, so a save cannot queue its check. Drops that one error and forwards the rest to
// the logger that data points to.
@(private = "file")
without_check_queue_error :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	if strings.has_prefix(text, "check queue full") do return
	outer := (^log.Logger)(data)
	outer.procedure(outer.data, level, text, options, location)
}

@(test)
lint_refresh_save_relints_sibling :: proc(t: ^testing.T) {
	with_package(
		t,
		B_CALLS,
		proc(t: ^testing.T, pkg: ^Refresh_Package) {
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)

			// The change runs with diagnostics off, so it lints nothing and a.odin keeps its stale verdict. Only the
			// save can clear it.
			pkg.config.enable_diagnostics = false
			changed := change_b(t, pkg, B_REGISTERS)
			pkg.config.enable_diagnostics = true
			if !changed do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)

			params_text := fmt.tprintf(
				`{{"textDocument":{{"uri":"%s"}},"text":%q}}`,
				file_uri(pkg, "b.odin"),
				B_REGISTERS,
			)
			params, parse_err := json.parse_string(
				params_text,
				parse_integers = true,
				allocator = context.temp_allocator,
			)
			if !testing.expectf(t, parse_err == .None, "failed to parse didSave params: %v", parse_err) do return
			outer := context.logger
			context.logger = {without_check_queue_error, &outer, outer.lowest_level, outer.options}
			save_err := server.notification_did_save(params, i64(0), &pkg.config, nil)
			context.logger = outer
			if !testing.expectf(t, save_err == .None, "didSave failed: %v", save_err) do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 0)
		},
	)
}

@(private = "file")
notify :: proc(
	t: ^testing.T,
	pkg: ^Refresh_Package,
	handler: proc(_: json.Value, _: server.RequestId, _: ^common.Config, _: ^server.Writer) -> common.Error,
	params_text: string,
) -> bool {
	params, parse_err := json.parse_string(params_text, parse_integers = true, allocator = context.temp_allocator)
	if !testing.expectf(t, parse_err == .None, "failed to parse params %s: %v", params_text, parse_err) do return false
	err := handler(params, i64(0), &pkg.config, nil)
	return testing.expectf(t, err == .None, "notification failed: %v", err)
}

@(test)
lint_refresh_close_of_dirty_buffer_relints_sibling :: proc(t: ^testing.T) {
	with_package(
		t,
		B_CALLS,
		proc(t: ^testing.T, pkg: ^Refresh_Package) {
			if !change_b(t, pkg, B_REGISTERS) do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 0)

			// The disk still holds B_CALLS, which only calls f.
			params := fmt.tprintf(`{{"textDocument":{{"uri":"%s"}}}}`, file_uri(pkg, "b.odin"))
			if !notify(t, pkg, server.notification_did_close, params) do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)
		},
	)
}

@(test)
lint_refresh_open_with_unsaved_text_relints_sibling :: proc(t: ^testing.T) {
	with_package(
		t,
		B_UNRELATED,
		proc(t: ^testing.T, pkg: ^Refresh_Package) {
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)
			server.document_close(file_uri(pkg, "b.odin"))

			// The disk still holds B_UNRELATED, but the buffer registers f.
			open_err := server.document_open(file_uri(pkg, "b.odin"), strings.clone(B_REGISTERS), &pkg.config, nil)
			if !testing.expectf(t, open_err == .None, "failed to reopen b.odin: %v", open_err) do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 0)
		},
	)
}

@(test)
lint_refresh_watched_file_change_relints_sibling :: proc(t: ^testing.T) {
	with_package(
		t,
		B_CALLS,
		proc(t: ^testing.T, pkg: ^Refresh_Package) {
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)
			server.document_close(file_uri(pkg, "b.odin"))

			// b.odin changes outside the editor while closed.
			write_err := os.write_entire_file(file_path(pkg, "b.odin"), transmute([]u8)string(B_REGISTERS))
			if !testing.expectf(t, write_err == nil, "failed to write b.odin: %v", write_err) do return
			changed := fmt.tprintf(`{{"changes":[{{"uri":"%s","type":2}}]}}`, file_uri(pkg, "b.odin"))
			if !notify(t, pkg, server.notification_did_change_watched_files, changed) do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 0)

			remove_err := os.remove(file_path(pkg, "b.odin"))
			if !testing.expectf(t, remove_err == nil, "failed to remove b.odin: %v", remove_err) do return
			deleted := fmt.tprintf(`{{"changes":[{{"uri":"%s","type":3}}]}}`, file_uri(pkg, "b.odin"))
			if !notify(t, pkg, server.notification_did_change_watched_files, deleted) do return
			testing.expect_value(t, unused_parameters_of_a(pkg), 1)
		},
	)
}
