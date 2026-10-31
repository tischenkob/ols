package server

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"
import "core:sync"
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

// In order of how much is checked, as requests checked together check as much as the largest
Check_Mode :: enum {
	Changed,
	Saved,
	Workspace,
}

Check_Request :: struct {
	check_mode: Check_Mode,
	path:       string,
	buffers:    []Check_Buffer,
	sequence:   u64, // when it was queued, so the newest buffers are checked
}

Check_Buffer :: struct {
	path:    string,
	text:    []u8,
	version: Maybe(int),
	session: u64,
}

Checker :: struct {
	allocator:              mem.Allocator,
	odin_without_workspace: string,
	dir:                    string, // Used by the -overlay and -exported-semantics
	overlay:                Check_Overlay,

	mutex:                  sync.Mutex,
	cond:                   sync.Cond,
	queue:                  [dynamic]Check_Request,
	changed:                Maybe(Check_Request), // only the newest change matters, so it replaces the one before
	sequence:               u64,
	stopped:                bool,
}

Check_Overlay :: struct {
	files: map[string]Check_Overlay_File, // by path
	json:  []u8,                          // as last written
}

Check_Overlay_File :: struct {
	file:    string,
	hash:    u64, // unchanged documents are not written again based of the text last written to `file`
	written: bool,
}

@(private = "file")
checker: Checker

queue_check_request :: proc(mode: Check_Mode, path: string, config: ^common.Config) {
	if !config.enable_diagnostics {
		return
	}
	path := strings.clone(path, checker.allocator)

	buffers := make([dynamic]Check_Buffer, 0, len(document_storage.documents), checker.allocator)
	for _, &document in document_storage.documents {
		if !document.client_owned || is_ols_builtin_file(document.fullpath) {
			continue
		}
		append(
			&buffers,
			Check_Buffer {
				path    = strings.clone(document.fullpath, checker.allocator),
				text    = slice.clone(document.text[:document.used_text], checker.allocator),
				version = document.version,
				session = document.session,
			},
		)
	}

	request := Check_Request{
		check_mode = mode,
		path       = path,
		buffers    = buffers[:],
	}

	sync.mutex_lock(&checker.mutex)
	checker.sequence += 1
	request.sequence = checker.sequence
	if mode == .Changed {
		if older, has_older := checker.changed.?; has_older {
			delete(older.path, checker.allocator)
			delete_check_buffers(older.buffers)
		}
		checker.changed = request
	} else {
		append(&checker.queue, request)
	}
	sync.mutex_unlock(&checker.mutex)

	sync.cond_signal(&checker.cond)
}

@(private = "file")
delete_check_buffers :: proc(buffers: []Check_Buffer) {
	for b in buffers {
		delete(b.path, checker.allocator)
		delete(b.text, checker.allocator)
	}
	delete(buffers, checker.allocator)
}

stop_check_worker :: proc() {
	sync.mutex_lock(&checker.mutex)
	checker.stopped = true
	sync.mutex_unlock(&checker.mutex)

	sync.cond_broadcast(&checker.cond)

	if checker.dir != "" {
		_ = os.remove_all(checker.dir)
	}
}

@(private = "file")
checker_dir :: proc() -> string {
	if checker.dir == "" {
		temp, err := os.temp_directory(context.temp_allocator)
		if err != nil {
			log.errorf("Failed to find the temporary directory: %v", err)
			return ""
		}
		checker.dir = fmt.aprintf("%s/ols-%d", temp, os.get_pid(), allocator = checker.allocator)
		_ = os.make_directory(checker.dir)
	}
	return checker.dir
}

create_and_start_check_worker :: proc(writer: ^Writer) {
	checker = Checker {
		allocator = runtime.heap_allocator(),
		queue     = make([dynamic]Check_Request, runtime.heap_allocator()),
	}
	thread.create_and_start_with_poly_data(Consumer{logger = context.logger, w = writer}, run_check_consumer)
}

Consumer :: struct {
	logger: log.Logger,
	w:      ^Writer,
}

@(private = "file")
Check_Batch :: struct {
	mode:     Check_Mode,
	paths:    [dynamic]string,
	buffers:  []Check_Buffer,
	sequence: u64, // Where the request `buffers` came from
}

@(private = "file")
add_to_check_batch :: proc(batch: ^Check_Batch, request: Check_Request) {
	if request.path != "" {
		append(&batch.paths, request.path)
	}
	if request.sequence > batch.sequence {
		delete_check_buffers(batch.buffers)
		batch.buffers = request.buffers
		batch.sequence = request.sequence
	} else {
		delete_check_buffers(request.buffers)
	}
	if request.check_mode > batch.mode {
		batch.mode = request.check_mode
	}
}

run_check_consumer :: proc(c: Consumer) {
	context.logger = c.logger
	// rols: the check failure last shown to the user
	shown: string
	defer delete(shown, runtime.heap_allocator())
	for {
		batch := Check_Batch {
			paths = make([dynamic]string, allocator = context.temp_allocator),
		}

		sync.mutex_lock(&checker.mutex)
		for !checker.stopped && len(checker.queue) == 0 && checker.changed == nil {
			sync.cond_wait(&checker.cond, &checker.mutex)
		}
		if checker.stopped {
			sync.mutex_unlock(&checker.mutex)
			break
		}

		last_change: time.Tick
		for {
			for request in checker.queue {
				add_to_check_batch(&batch, request)
			}
			clear(&checker.queue)
			if changed, has_changed := checker.changed.?; has_changed {
				add_to_check_batch(&batch, changed)
				checker.changed = nil
				last_change = time.tick_now()
			}

			if batch.mode != .Changed || checker.stopped {
				break
			}
			remaining := time.Duration(common.config.checker_on_change_delay) * time.Millisecond - time.tick_since(last_change)
			if remaining <= 0 {
				break
			}
			sync.cond_wait_with_timeout(&checker.cond, &checker.mutex, remaining)
		}
		sync.mutex_unlock(&checker.mutex)

		semantics := check(batch.mode, batch.paths[:], batch.buffers, &common.config)
		// rols: show a check that did not run, such as odin refusing a Windows target on another host
		report_check_failure(c.w, &shown)

		// NOTE(bill): This is loaded first as it adds the hints for the untaken branches of `when` statements
		if common.config.enable_compiler_semantics {
			load_semantics(semantics, batch.buffers, batch.mode == .Workspace)
		}
		push_diagnostics(c.w)
		for path in batch.paths {
			delete(path, checker.allocator)
		}
		delete_check_buffers(batch.buffers)

		free_all(context.temp_allocator)
	}
	free_all(context.temp_allocator)
}

fallback_find_odin_directories :: proc(config: ^common.Config) -> []string {
	data := make([dynamic]string, context.temp_allocator)

	for workspace in config.workspace_folders {
		uri := common.parse_uri(workspace.uri, context.temp_allocator) or_continue
		// rols: skip git-ignored and excluded paths, one filter per root
		filter := common.workspace_filter_make(uri.path, config, context.temp_allocator)
		append_packages(uri.path, &data, config.checker_skip_packages, context.temp_allocator, filter = &filter)
	}

	return data[:]
}

check_unused_imports :: proc(document: ^Document, config: ^common.Config, semantics_only := false) {
	if !config.enable_unused_imports_reporting || !config.enable_diagnostics {
		return
	}

	spall.trace(#procedure, document.fullpath)

	path := document.uri.path

	when ODIN_OS == .Windows {
		path = common.get_case_sensitive_path(path, context.temp_allocator)
	}

	uri := common.create_uri(path, context.temp_allocator)

	if len(document.imports) == 0 {
		remove_diagnostics(.Unused, uri.uri)
		return
	}

	unused_imports: []Package
	found := false
	if config.enable_compiler_semantics {
		unused_imports, found = semantics_unused_imports(document)
	}
	if !found {
		if semantics_only {
			return
		}
		unused_imports = find_unused_imports(document, context.temp_allocator)
	}

	remove_diagnostics(.Unused, uri.uri)
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
			// rols: the caller's config gates the store
			config,
		)
	}
}

resolve_check_paths :: proc(mode: Check_Mode, paths: []string, config: ^common.Config) -> []string {
	if len(config.profile.checker_path) > 0 {
		return config.profile.checker_path[:]
	}

	if mode != .Workspace || config.enable_checker_only_saved {
		results := make([dynamic]string, context.temp_allocator)
		for p in paths {
			if p == "" {
				continue
			}
			dir := path.dir(p, context.temp_allocator)
			if dir not_in config.checker_skip_packages && !slice.contains(results[:], dir) {
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
	// rols: the reruns: the job's paths and semantics file, whether the command has style flags, whether this is
	// the rerun without them, the errors of the first run that the rerun merges with, whether this run restarts
	// one that a signal killed with no output, and whether this run crashed so and was restarted
	paths:     []string,
	semantics: string,
	style:     bool,
	rerun:     bool,
	first:     Json_Errors,
	retry:     bool,
	crashed:   bool,
}

// rols: timeout, the budget of the whole run, is scaled by the CLI; per_package runs one process per path, so
// the CLI compile gate knows which package an error came from
check :: proc(
	mode: Check_Mode,
	check_paths: []string,
	buffers: []Check_Buffer,
	config: ^common.Config,
	timeout := CHECK_TIMEOUT,
	per_package := false,
) -> (
	semantics: []string,
) {
	write_overlay :: proc(o: ^Check_Overlay, buffers: []Check_Buffer) -> string {
		dir := checker_dir()
		if len(buffers) == 0 || dir == "" {
			return ""
		}

		Overlay :: struct {
			replace: map[string]string `json:"Replace"`,
		}
		overlay := Overlay {
			replace = make(map[string]string, len(buffers), context.temp_allocator),
		}
		if o.files == nil {
			o.files = make(map[string]Check_Overlay_File, 16, checker.allocator)
		}
		for b in buffers {
			entry := &o.files[b.path]
			if entry == nil {
				path := strings.clone(b.path, checker.allocator)
				o.files[path] = {file = fmt.aprintf("%s/%d.odin", dir, len(o.files), allocator = checker.allocator)}
				entry = &o.files[path]
			}
			h := hash.fnv64a(b.text)
			if !entry.written || entry.hash != h {
				if err := os.write_entire_file(entry.file, b.text); err != nil {
					log.errorf("Failed to write the overlay file %q: %v", entry.file, err)
					return ""
				}
				entry.hash = h
				entry.written = true
			}
			overlay.replace[b.path] = entry.file
		}

		data, err := json.marshal(overlay, {sort_maps_by_key = true}, context.temp_allocator)
		if err != nil {
			log.errorf("Failed to make the overlay: %v", err)
			return ""
		}
		path := fmt.tprintf("%s/overlay.json", dir)
		if !slice.equal(data, o.json) {
			if err := os.write_entire_file(path, data); err != nil {
				log.errorf("Failed to write the overlay %q: %v", path, err)
				return ""
			}
			delete(o.json, checker.allocator)
			o.json = slice.clone(data, checker.allocator)
		}
		return path
	}

	paths := resolve_check_paths(mode, check_paths, config)

	if len(paths) == 0 {
		return
	}

	clear_diagnostics(.Check)

	// rols: the CLI checks without the check worker, which sets the allocator
	if checker.allocator.procedure == nil {
		checker.allocator = runtime.heap_allocator()
	}

	command := config.odin_command
	if command == "" {
		command = "odin"
	}

	collections := make([dynamic]string, context.temp_allocator)

	for k, v in common.config.collections {
		if k == "" || k == "core" || k == "vendor" || k == "base" {
			continue
		}
		// rols: temp memory: the argument list dies with the check
		append(&collections, fmt.tprintf("-collection:%v=%v", k, v))
	}

	jobs := make([dynamic][]string, 0, len(paths), context.temp_allocator)
	overlay := ""
	// rols: and not per_package
	use_workspace := command != checker.odin_without_workspace && !per_package
	if use_workspace {
		overlay = write_overlay(&checker.overlay, buffers)

		// NOTE(bill): This is here just to keep the command line well within Windows' limit of 32767 characters
		MAX_WORKSPACE_PATHS_LEN :: 16384

		dirs := make([dynamic]string, 0, len(paths), context.temp_allocator)
		dirs_len := 0
		for p, i in paths {
			if filepath.ext(p) == ".odin" {
				append(&jobs, paths[i:i + 1])
				continue
			}
			if dirs_len + len(p) > MAX_WORKSPACE_PATHS_LEN && len(dirs) > 0 {
				append(&jobs, dirs[:])
				dirs = make([dynamic]string, 0, len(paths), context.temp_allocator)
				dirs_len = 0
			}
			append(&dirs, p)
			dirs_len += len(p) + 3
		}
		if len(dirs) > 0 {
			append(&jobs, dirs[:])
		}
	} else {
		for _, i in paths {
			append(&jobs, paths[i:i + 1])
		}
	}

	max_concurrent_checks := max(1, os.get_processor_core_count())
	// rols: temp memory, freed with the check
	processes := make([dynamic]CheckProcess, 0, len(jobs), context.temp_allocator)

	errors   := make([dynamic]Json_Errors, 0, len(jobs), context.temp_allocator)
	exported := make([dynamic]string, 0, len(jobs), context.temp_allocator)
	lacks_workspace := false

	next_index := 0
	running_count := 0
	start := time.now()
	// rols: a Syntax Error of a style flag stops checking, so the job runs again without the flags, and the
	// budget doubles once for all reruns. A run that a signal killed before it printed anything runs once more in
	// the same budget. parsed counts the outputs that unmarshalled. The source of a file decides the severity of
	// an unused variable, and odin reads the overlay buffers only with an overlay. error_files holds the files
	// that each one-path job's errors name, for the CLI compile gate.
	pending_reruns := make([dynamic]CheckProcess, context.temp_allocator)
	parsed := 0
	budget := timeout
	sources := buffers if overlay != "" else nil
	hard_unused := make(Hard_Unused_Cache, context.temp_allocator)
	check_run.error_files = make(map[string][dynamic]string, context.temp_allocator)

	for running_count > 0 || next_index < len(jobs) || len(pending_reruns) > 0 {
		// rols: start the queued style reruns and crash restarts
		for first in pending_reruns {
			if first.semantics != "" {
				_ = os.remove(first.semantics)
			}
			p, ok := start_check_process(command, first.paths, collections[:], overlay, first.semantics, config, first.rerun)
			if ok {
				p.first = first.first
				p.retry = first.retry
				append(&processes, p)
				running_count += 1
				if !first.retry {
					budget = 2 * timeout
				}
			} else {
				append(&errors, first.first)
			}
		}
		clear(&pending_reruns)
		for running_count < max_concurrent_checks && next_index < len(jobs) {
			semantics_file := ""
			if config.enable_compiler_semantics && use_workspace && checker_dir() != "" {
				semantics_file = fmt.tprintf("%s/semantics-%d.cbor", checker_dir(), next_index)
				_ = os.remove(semantics_file)
			}
			p, ok := start_check_process(command, jobs[next_index], collections[:], overlay, semantics_file, config)
			next_index += 1
			if !ok {
				continue
			}
			if semantics_file != "" {
				append(&exported, semantics_file)
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

			// rols: the signal that killed the child, read before process_wait reaps it
			signal, exited := child_exit_signal(p.process)
			if !exited {
				continue
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

			output := string(p.buffer[:])
			if use_workspace {
				for flag in ([]string{"'workspace'", "'overlay'", "'export-semantics'"}) {
					lacks_workspace ||= strings.contains(output, fmt.tprintf("Unknown flag: %s", flag))
				}
				if lacks_workspace {
					continue
				}
			}

			// rols: a run that a signal killed before it printed anything runs once more
			if signal != 0 && len(p.buffer) == 0 {
				log.errorf("`odin check %v` was killed by signal %d before it printed anything", p.paths, signal)
				if !p.retry {
					p.crashed = true
					append(
						&pending_reruns,
						CheckProcess{paths = p.paths, semantics = p.semantics, first = p.first, rerun = p.rerun, retry = true},
					)
					continue
				}
			}

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
				// rols: record the files that a one-path job's errors name; the rerun merges with the first run, and a
				// Syntax Error of a style check starts the rerun unless a file that a stopping error names has a
				// syntax error of its own
				parsed += 1
				if len(p.paths) == 1 {
					note_error_files(p.paths[0], json_errors)
				}
				if p.rerun {
					json_errors = merge_style_rerun(p.first, json_errors)
				} else if p.style && has_stopping_error(json_errors) && !has_real_syntax_error(json_errors, sources) {
					append(
						&pending_reruns,
						CheckProcess{paths = p.paths, semantics = p.semantics, first = json_errors, rerun = true},
					)
					continue
				}
				append(&errors, json_errors)
			} else if p.rerun {
				// rols: a rerun that exits with 0 and prints nothing found no error, and one that fails left the first run
				append(&errors, merge_style_rerun(p.first, {}) if state.exit_code == 0 else p.first)
			}
		}

		if running_count > 0 || next_index < len(jobs) {
			time.sleep(1 * time.Millisecond)
		}
	}

	// rols: a rerun that the timeout cut short leaves the first run
	for p in processes {
		if p.rerun && !p.finished {
			append(&errors, p.first)
		}
	}

	for p in processes {
		os.close(p.reader)
	}

	if lacks_workspace {
		log.infof("`%s` has no `-workspace` or `-overlay`, so packages are checked one at a time from disk", command)
		delete(checker.odin_without_workspace, checker.allocator)
		checker.odin_without_workspace = strings.clone(command, checker.allocator)
		// rols: forget the probe's exits, and pass timeout and per_package on
		forget_check_exits()
		return check(mode, check_paths, buffers, config, timeout, per_package)
	}

	// rols: record whether every job ran to a parsed result
	record_check_run(len(jobs), processes[:], parsed)

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
					severity = check_error_severity(error, message, &hard_unused, sources),
					range = {
						// odin will sometimes report errors on column 0, so we ensure we don't provide a negative column/line to the client
						start = {character = max(error.pos.column - 1, 0), line = max(error.pos.line - 1, 0)},
						end = {character = max(error.pos.end_column - 1, 0), line = max(error.pos.line - 1, 0)},
					},
					message = message,
				},
				// rols: the caller's config gates the store
				config,
			)
		}

	}

	return exported[:]
}


@(private = "file")
start_check_process :: proc(
	command:     string,
	check_paths: []string,
	collections: []string,
	overlay:     string,
	semantics:   string,
	config:      ^common.Config,
	// rols: the rerun leaves out the style flags
	rerun := false,
) -> (
	CheckProcess,
	bool,
) {
	entry_point_opt := filepath.ext(check_paths[0]) == ".odin" ? "-file" : "-no-entry-point"
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, command, "check")
	append(&cmd, ..check_paths)
	for c in collections {
		append(&cmd, c)
	}
	for k, v in config.profile.defines {
		append(&cmd, fmt.tprintf("-define:%s=%s", k, v))
	}
	append(&cmd, entry_point_opt, "-json-errors")
	if len(check_paths) > 1 {
		append(&cmd, "-workspace")
	}
	if len(check_paths) > 1 || semantics != "" {
		// TODO(bill): is this a good idea to change the limit to 1000?
		// NOTE(bill): The semantics are not exported once the errors reach it either
		append(&cmd, "-max-error-count:1000")
	}
	if overlay != "" {
		append(&cmd, fmt.tprintf("-overlay:%s", overlay))
	}
	if semantics != "" {
		append(&cmd, "-export-semantics:cbor", fmt.tprintf("-export-semantics-file:%s", semantics))
	}
	// rols: the vet flags and the checker_args without repeated flags, and without the style flags in the rerun
	command_line, style := finish_check_command(cmd[:], config, rerun)

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
		command = command_line,
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
	// rols: the rerun fields
	return CheckProcess {
			process = p,
			reader = r,
			buffer = buffer,
			paths = check_paths,
			semantics = semantics,
			style = style,
			rerun = rerun,
		},
		true
}
