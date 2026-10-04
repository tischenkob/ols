package server

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:strings"
import "core:sync/chan"
import "core:thread"
import "core:time"

import "src:common"
import "src:spall"

Json_Error :: struct {
	type: string,
	pos:  Json_Type_Error,
	msgs: []string,
}

Json_Type_Error :: struct {
	file:       string,
	offset:     int,
	line:       int,
	column:     int,
	end_column: int,
}

Json_Errors :: struct {
	error_count: int,
	errors:      []Json_Error,
}

// rols: the default wall-clock budget of one `check`, shared by all its packages
CHECK_TIMEOUT :: 20 * time.Second

Check_Mode :: enum {
	Saved,
	Workspace,
}

Check_Request :: struct {
	check_mode: Check_Mode,
	path:       string,
	config:     ^common.Config,
}

Checker :: struct {
	allocator: mem.Allocator,
	send:      chan.Chan(Check_Request, .Send),
}

@(private = "file")
checker: Checker

queue_check_request :: proc(mode: Check_Mode, path: string, config: ^common.Config) {
	if !config.enable_diagnostics {
		return
	}
	path := strings.clone(path, checker.allocator)
	// rols: never block the request thread on a full queue
	if !chan.try_send(checker.send, Check_Request{check_mode = mode, path = path, config = config}) {
		log.errorf("check queue full, dropping %q", path)
		delete(path, checker.allocator)
	}
}

stop_check_worker :: proc() {
	chan.close(checker.send)
}

create_and_start_check_worker :: proc(writer: ^Writer) {
	allocator := runtime.heap_allocator()
	check_chan, _ := chan.create(chan.Chan(Check_Request), 8, context.allocator)
	check_send := chan.as_send(check_chan)
	checker = Checker {
		allocator = runtime.heap_allocator(),
		send      = check_send,
	}
	check_recv := chan.as_recv(check_chan)
	thread.create_and_start_with_poly_data(
		Consumer{logger = context.logger, ch = check_recv, w = writer},
		run_check_consumer,
	)
}

Consumer :: struct {
	logger: log.Logger,
	ch:     chan.Chan(Check_Request, .Recv),
	w:      ^Writer,
}

run_check_consumer :: proc(c: Consumer) {
	context.logger = c.logger
	for {
		request, ok := chan.recv(c.ch)
		if !ok {
			break
		}
		paths := make([dynamic]string, allocator = context.temp_allocator)
		append(&paths, request.path)
		for request in chan.try_recv(c.ch) {
			append(&paths, request.path)
		}
		check(request.check_mode, paths[:], request.config)
		push_diagnostics(c.w)
		for path in paths {
			delete(path, checker.allocator)
		}
		free_all(context.temp_allocator)
	}
	free_all(context.temp_allocator)
}

//If the user does not specify where to call odin check, it'll just find all directory with odin, and call them seperately.
fallback_find_odin_directories :: proc(config: ^common.Config) -> []string {
	data := make([dynamic]string, context.temp_allocator)

	for workspace in config.workspace_folders {
		if uri, ok := common.parse_uri(workspace.uri, context.temp_allocator); ok {
			// rols: skip git-ignored and excluded paths, one filter per root
			filter := common.workspace_filter_make(uri.path, config, context.temp_allocator)
			append_packages(uri.path, &data, config.checker_skip_packages, context.temp_allocator, filter = &filter)
		}
	}

	return data[:]
}

check_unused_imports :: proc(document: ^Document, config: ^common.Config) {
	if !config.enable_unused_imports_reporting || !config.enable_diagnostics {
		return
	}

	spall.trace(#procedure, document.fullpath)

	path := document.uri.path

	when ODIN_OS == .Windows {
		path = common.get_case_sensitive_path(path, context.temp_allocator)
	}

	uri := common.create_uri(path, context.temp_allocator)

	remove_diagnostics(.Unused, uri.uri)
	if len(document.imports) == 0 {
		return
	}

	unused_imports := find_unused_imports(document, context.temp_allocator)

	for imp in unused_imports {
		add_diagnostics(
			.Unused,
			uri.uri,
			Diagnostic {
				range = common.get_token_range(imp.import_decl, document.ast.src),
				severity = DiagnosticSeverity.Hint,
				code = "Unused",
				message = "unused import",
				tags = {.Unnecessary},
			},
		)
	}
}

resolve_check_paths :: proc(mode: Check_Mode, paths: []string, config: ^common.Config) -> []string {
	if len(config.profile.checker_path) > 0 {
		return config.profile.checker_path[:]
	}

	if mode == .Saved || config.enable_checker_only_saved {
		results := make([dynamic]string, context.temp_allocator)
		for p in paths {
			if p == "" {
				continue
			}
			dir := path.dir(p, context.temp_allocator)
			if dir not_in config.checker_skip_packages {
				append(&results, dir)
			}
		}
		return results[:]
	}

	if mode == .Workspace && config.enable_checker_workspace_diagnostics {
		return fallback_find_odin_directories(config)
	}

	return {}
}

CheckProcess :: struct {
	process:  os.Process,
	reader:   ^os.File,
	finished: bool,
	buffer:   [dynamic]u8,
	// rols: the style rerun: the check path, whether the command has style flags, whether this is the
	// rerun without them, and the errors of the first run that the rerun merges with
	path:     string,
	style:    bool,
	rerun:    bool,
	first:    Json_Errors,
}

// rols: timeout, the budget of the whole run, is scaled by the CLI compile gate
check :: proc(mode: Check_Mode, check_paths: []string, config: ^common.Config, timeout := CHECK_TIMEOUT) {
	paths := resolve_check_paths(mode, check_paths, config)

	if len(paths) == 0 {
		return
	}

	clear_diagnostics(.Check)

	collections := make([dynamic]string, context.temp_allocator)

	for k, v in common.config.collections {
		if k == "" || k == "core" || k == "vendor" || k == "base" {
			continue
		}
		// rols: temp memory: the argument list dies with the check
		append(&collections, fmt.tprintf("-collection:%v=%v", k, v))
	}

	max_concurrent_checks := max(1, os.get_processor_core_count())
	// rols: temp memory, freed with the check
	processes := make([dynamic]CheckProcess, 0, len(paths), context.temp_allocator)

	errors := make([dynamic]Json_Errors, 0, len(paths), context.temp_allocator)
	// rols: the source of a file decides the severity of an unused variable
	hard_unused := make(Hard_Unused_Cache, context.temp_allocator)

	next_index := 0
	running_count := 0
	start := time.now()
	// rols: a Syntax Error of a style flag stops checking, so the package runs again without the flags,
	// and the budget doubles once for all reruns. parsed counts the outputs that unmarshalled.
	pending_reruns := make([dynamic]CheckProcess, context.temp_allocator)
	parsed := 0
	budget := timeout

	for running_count > 0 || next_index < len(paths) || len(pending_reruns) > 0 {
		for first in pending_reruns {
			p, ok := start_check_process(first.path, collections[:], config, true)
			if ok {
				p.first = first.first
				append(&processes, p)
				running_count += 1
				budget = 2 * timeout
			} else {
				append(&errors, first.first)
			}
		}
		clear(&pending_reruns)
		for running_count < max_concurrent_checks && next_index < len(paths) {
			p, ok := start_check_process(paths[next_index], collections[:], config)
			next_index += 1
			if !ok {
				continue
			}
			append(&processes, p)
			running_count += 1
		}

		// rols: the caller's budget
		if time.since(start) > budget {
			log.error("`odin check` timed out")
			for &p in processes {
				if !p.finished {
					// rols: reap the process we killed
					if err := os.process_kill(p.process); err != nil {
						log.errorf("Failed to kill `odin check` process: %v", err)
					} else {
						_, _ = os.process_wait(p.process)
					}
				}
			}
			break
		}

		for &p in processes {
			if p.finished {
				continue
			}

			// rols: drain the pipe: one read leaves the rest for the next poll
			buf: [4096]u8
			for {
				has_data, _ := os.pipe_has_data(p.reader)
				if !has_data {
					break
				}
				n, _ := os.read(p.reader, buf[:])
				if n <= 0 {
					break
				}
				_, _ = append(&p.buffer, ..buf[:n])
			}

			state, err := os.process_wait(p.process, 0)
			if err != nil {
				continue
			}

			if !state.exited {
				continue
			}

			p.finished = true
			running_count -= 1
			// rols: the exit status for record_check_run
			note_check_exit(p.process, state.exit_code)

			for {
				n, read_err := os.read(p.reader, buf[:])
				if n > 0 {
					_, _ = append(&p.buffer, ..buf[:n])
				}
				if read_err != nil {
					break
				}
			}

			os.close(p.reader)
			p.reader = nil

			if len(p.buffer) > 0 {
				json_errors: Json_Errors
				if res := json.unmarshal(
					p.buffer[:],
					&json_errors,
					json.DEFAULT_SPECIFICATION,
					context.temp_allocator,
				); res != nil {
					log.errorf("Failed to unmarshal check results: %v, %v", res, string(p.buffer[:]))
					// rols: a rerun that cannot be read leaves the first run
					if p.rerun {
						append(&errors, p.first)
					}
					continue
				}
				parsed += 1
				// rols: the rerun merges with the first run, a Syntax Error of a style check starts the rerun
				if p.rerun {
					json_errors = merge_style_rerun(p.first, json_errors)
				} else if p.style && has_stopping_error(json_errors) {
					append(&pending_reruns, CheckProcess{path = p.path, first = json_errors})
					continue
				}
				append(&errors, json_errors)
			} else if p.rerun {
				// rols: a rerun that exits with 0 and prints nothing found no error, and one that fails left
				// the first run
				append(&errors, merge_style_rerun(p.first, {}) if state.exit_code == 0 else p.first)
			}
		}

		if running_count > 0 || next_index < len(paths) {
			time.sleep(1 * time.Millisecond)
		}
	}

	// rols: a rerun that the timeout cut short leaves the first run
	for p in processes {
		if p.rerun && !p.finished {
			append(&errors, p.first)
		}
	}

	// rols: record whether every package check ran to a parsed result
	record_check_run(len(paths), processes[:], parsed)

	for p in processes {
		os.close(p.reader)
	}

	DiagnosticKey :: struct {
		path:    string,
		message: string,
		line:    int,
		column:  int,
	}

	diagnostics := make(map[DiagnosticKey]struct{}, context.temp_allocator)
	for e in errors {
		for error in e.errors {
			if len(error.msgs) == 0 {
				continue
			}

			message := strings.join(error.msgs, "\n", context.temp_allocator)

			if strings.contains(message, "Redeclaration of 'main' in this scope") {
				continue
			}

			path := error.pos.file

			when ODIN_OS == .Windows {
				path = common.get_case_sensitive_path(path, context.temp_allocator)
				path, _ = filepath.replace_separators(path, '/', context.temp_allocator)
			}

			key := DiagnosticKey {
				path    = path,
				message = message,
				line    = error.pos.line,
				column  = error.pos.column,
			}
			if key in diagnostics {
				continue
			}

			diagnostics[key] = {}

			if is_ols_builtin_file(path) {
				continue
			}

			uri := common.create_uri(path, context.temp_allocator)

			add_diagnostics(
				.Check,
				uri.uri,
				Diagnostic {
					code = "checker",
					// rols: the message and the source decide whether a vet error is a warning
					severity = check_error_severity(error, message, &hard_unused),
					range = {
						// odin will sometimes report errors on column 0, so we ensure we don't provide a negative column/line to the client
						start = {character = max(error.pos.column - 1, 0), line = max(error.pos.line - 1, 0)},
						end = {character = max(error.pos.end_column - 1, 0), line = max(error.pos.line - 1, 0)},
					},
					message = message,
				},
			)
		}

	}

}
@(private = "file")
start_check_process :: proc(
	check_path: string,
	collections: []string,
	config: ^common.Config,
	// rols: the rerun leaves out the style flags
	rerun := false,
) -> (
	CheckProcess,
	bool,
) {
	// rols: the command line comes from check_command, which drops repeated flags
	cmd := check_command(check_path, collections, config)
	// rols: the style flags that turn a style slip into a Syntax Error
	style := style_flags_on(cmd)
	if rerun {
		cmd = without_style_flags(cmd)
	}

	// rols: spawn lock from pipe creation until the deferred close of the write end
	common.process_spawn_lock()
	defer common.process_spawn_unlock()

	r, w, err := os.pipe()
	if err != nil {
		log.errorf("failed to create pipe for `odin check`: %v\n", err)
		return CheckProcess{}, false
	}
	defer os.close(w)

	desc := os.Process_Desc {
		command = cmd,
		stdout  = w,
		stderr  = w,
	}

	p, perr := os.process_start(desc)
	if perr != nil {
		os.close(r)
		log.errorf("failed to start process for `odin check`: %v\n", perr)
		return CheckProcess{}, false
	}

	buffer := make([dynamic]u8, 0, mem.Kilobyte * 200, context.temp_allocator)
	// rols: the style rerun fields
	return CheckProcess{process = p, reader = r, buffer = buffer, path = check_path, style = style, rerun = rerun}, true
}

// rols: vet findings report as warnings, and syntax errors as errors whatever their type
map_diagnostic_severity :: proc(type: string, message: string) -> DiagnosticSeverity {
	// -json-errors types some syntax errors as warnings, such as an import path that does not exist.
	if strings.has_prefix(message, "Syntax Error") {
		return .Error
	}
	if strings.equal_fold(type, "warning") {
		return .Warning
	}

	// The shadowing and cast vet flags are ours, not the user's build, so their errors show as warnings. The
	// "declared but not used" message stays an error here: odin prints the same text, without a vet flag, for
	// `if c { x := 1 }`, which is a compile error. check_error_severity reads the source to tell them apart.
	vet_messages := [?]string{"shadows declaration", "Unneeded cast", "Unneeded transmute"}
	for m in vet_messages {
		if strings.contains(message, m) {
			return .Warning
		}
	}

	return .Error
}
