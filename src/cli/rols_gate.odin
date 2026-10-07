package cli

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

import "src:common"
import "src:server"

// The 1-based lines an edit replaces or inserts into, first to last.
Line_Span :: struct {
	first, last: int,
}

// The lines the edits of a refactor change, per file as `odin check` spells its path.
Edited_Lines :: map[string][]Line_Span

// The lines that edit changes in each file it addresses by uri.
edited_lines :: proc(edit: server.WorkspaceEdit) -> Edited_Lines {
	spans := make(map[string][dynamic]Line_Span, context.temp_allocator)
	add :: proc(spans: ^map[string][dynamic]Line_Span, uri: string, edits: []server.TextEdit) {
		file := server.canonical_dir(common.uri_to_path(uri, context.temp_allocator))
		list := spans[file]
		for e in edits {
			append(&list, Line_Span{e.range.start.line + 1, e.range.end.line + 1})
		}
		spans[file] = list
	}
	if changes, has := edit.documentChanges.?; has {
		for change in changes {
			if c, ok := change.(server.TextDocumentEdit); ok {
				add(&spans, c.textDocument.uri, c.edits)
			}
		}
	}
	for uri, edits in edit.changes {
		add(&spans, uri, edits)
	}
	result := make(Edited_Lines, context.temp_allocator)
	for file, list in spans {
		result[file] = list[:]
	}
	return result
}

// Whether the position of e is on a line that edited changes in its file.
on_edited_line :: proc(edited: Edited_Lines, e: Check_Error) -> bool {
	// A range over the map index itself loops forever for a missing key (Odin dev-2026-09).
	spans := edited[e.file]
	for span in spans {
		if e.line >= span.first && e.line <= span.last {
			return true
		}
	}
	return false
}

// The checks of the gate without checker_variants: dirs, every package directory, on the current target
// first, then one check per other target. A target that checker_targets names checks dirs. Another target
// is one that a file the current target does not build needs, or that a `when` condition of a file names
// (when_named_targets): a touched file, a file next to one, or a file of an importer directory. Its check
// covers the directories of those files, the directory of such a file that can take another `when` branch on
// it than on the current target, and their importers in graph. Before and after the write use the same
// checks. A touched file that no target builds gets a warning.
gate_targets :: proc(
	changed: []File_State,
	dirs, importers: []string,
	reasons: ^[dynamic]string,
	graph: server.Import_Graph,
) -> []Gate_Check {
	config := &common.config
	base := server.base_target(config.checker_args)

	everywhere := make(map[string]bool, context.temp_allocator)
	for entry in config.checker_targets {
		if name, ok := server.target_name(entry); ok {
			everywhere[name] = true
		} else {
			warn(reasons, fmt.tprintf("checker_targets: %q is not an odin target; skipped", entry))
		}
	}
	// Every text that decides the targets: the old and the new text of a touched file, since the edit can add
	// or drop a tag, each other file of a touched directory, such as lib_windows.odin beside an edited
	// lib.odin, which builds with it on its own target, and each file of an importer directory, which builds
	// the touched package on its own target.
	sources := make([dynamic]Gate_Source, context.temp_allocator)
	touched := make([dynamic]string, context.temp_allocator)
	for file in changed {
		if filepath.ext(file.path) != ".odin" {
			continue
		}
		dir := path.dir(file.path, context.temp_allocator)
		if !slice.contains(touched[:], dir) {
			append(&touched, dir)
		}
		if file.existed && (!file.exists || file.original != file.text) {
			append(&sources, Gate_Source{dir, file.path, file.original, true, nil})
		}
		if file.exists {
			append(&sources, Gate_Source{dir, file.path, file.text, true, nil})
		}
	}
	for dir in touched {
		add_dir_sources(&sources, dir, changed)
	}
	for dir in importers {
		add_dir_sources(&sources, dir, changed)
	}
	// Each other target to the directories of the files that need it.
	needs := make(map[string][dynamic]string, context.temp_allocator)
	for source in sources {
		note_target(&needs, reasons if source.touched else nil, source.dir, source.path, source.text, base)
	}
	consts := dir_consts(sources[:])
	// A `when ODIN_OS == .X` branch builds on X only, so X checks its directory even when no file needs X.
	for &source in sources {
		if !server.gate_may_name_target(source.text, consts[source.dir]) do continue
		for target in server.file_when_named_targets(source_file(&source), base, consts[source.dir]) {
			add_need(&needs, target, source.dir)
		}
	}
	// A branch can also differ on a target that another file needs, such as one under `ODIN_ARCH == .wasm32` on
	// wasi_wasm32, or one whose condition the gate cannot read.
	others := make([dynamic]string, context.temp_allocator)
	parsed := make([dynamic]parser.Build_Target, context.temp_allocator)
	for target in needs {
		append(&others, target)
		append(&parsed, server.parse_target(target) or_else parser.Build_Target{})
	}
	for &source in sources {
		if len(parsed) == 0 || !server.gate_may_name_target(source.text, consts[source.dir]) do continue
		for takes, i in server.file_branch_targets(source_file(&source), base, parsed[:], consts[source.dir]) {
			if takes do add_need(&needs, others[i], source.dir)
		}
	}

	targets := make([dynamic]string, context.temp_allocator)
	for target in everywhere {
		append(&targets, target)
	}
	for target in needs {
		if target not_in everywhere {
			append(&targets, target)
		}
	}
	slice.sort(targets[:])
	checks := make([dynamic]Gate_Check, context.temp_allocator)
	append(&checks, Gate_Check{dirs = dirs})
	for target in targets {
		if parsed, _ := server.parse_target(target); parsed == base {
			continue
		}
		if everywhere[target] {
			append(&checks, Gate_Check{target = target, dirs = dirs})
			continue
		}
		// The importers of these directories import the touched packages too, so the result lies within dirs.
		seeds := needs[target][:]
		importing := server.graph_importers(graph, seeds)
		append(
			&checks,
			Gate_Check {
				target = target,
				dirs = slice.concatenate([][]string{seeds, importing}, context.temp_allocator),
			},
		)
	}
	return checks[:]
}

// Adds dir to the directories of the target that the file called name with the source text needs, when the
// current target base does not build it. With reasons, a file that no target builds gets a warning.
@(private = "file")
note_target :: proc(
	needs: ^map[string][dynamic]string,
	reasons: ^[dynamic]string,
	dir, name, text: string,
	base: parser.Build_Target,
) {
	switch target, need := server.target_for_file(name, text, base); need {
	case .None:
	case .Other:
		add_need(needs, target, dir)
	case .Nowhere:
		if reasons != nil {
			warn(reasons, fmt.tprintf("%s builds on no target the gate knows, so the gate does not check it", name))
		}
	}
}

// Adds dir to the directories that check target.
@(private = "file")
add_need :: proc(needs: ^map[string][dynamic]string, target, dir: string) {
	list, found := needs[target]
	if !found {
		list = make([dynamic]string, context.temp_allocator)
	}
	if !slice.contains(list[:], dir) {
		append(&list, dir)
	}
	needs[target] = list
}

// The constants that the `when` conditions of each directory of sources can read, for a directory with a `when`
// in some file. A file with two texts gives those of its last one, the text after the edit.
@(private = "file")
dir_consts :: proc(sources: []Gate_Source) -> map[string]server.Gate_Consts {
	consts := make(map[string]server.Gate_Consts, context.temp_allocator)
	for source in sources {
		if strings.contains(source.text, "when") && source.dir not_in consts {
			consts[source.dir] = make(server.Gate_Consts, context.temp_allocator)
		}
	}
	last := make(map[string]int, context.temp_allocator)
	for source, i in sources do last[source.path] = i
	for &source, i in sources {
		if last[source.path] != i || source.dir not_in consts || !strings.contains(source.text, "::") do continue
		server.add_gate_consts(&consts[source.dir], source_file(&source))
	}
	return consts
}

// A text that decides the targets of the gate: a file in dir, and whether the edit touches it.
@(private = "file")
Gate_Source :: struct {
	dir, path, text: string,
	touched:         bool,
	// The parsed text, from source_file, so each text is parsed at most once.
	file:            ^ast.File,
}

// The parsed text of source.
@(private = "file")
source_file :: proc(source: ^Gate_Source) -> ^ast.File {
	if source.file == nil do source.file = server.parse_gate_text(source.path, source.text)
	return source.file
}

// Appends each .odin file of dir on disk that changed does not name to sources.
@(private = "file")
add_dir_sources :: proc(sources: ^[dynamic]Gate_Source, dir: string, changed: []File_State) {
	matches, _ := filepath.glob(strings.concatenate({dir, "/*.odin"}, context.temp_allocator), context.temp_allocator)
	next: for match in matches {
		for file in changed {
			if file.path == match do continue next
		}
		if data, err := os.read_entire_file(match, context.temp_allocator); err == nil {
			append(sources, Gate_Source{dir, match, string(data), false, nil})
		}
	}
}

// The package directories that the gate checks with one `-target:` value, empty for the current target,
// and the extra checker args of a checker_variants entry, empty for none.
Gate_Check :: struct {
	target: string,
	dirs:   []string,
	args:   string,
}

// checks followed by one check of dirs for each checker_variants entry, with its args. An entry of only
// whitespace adds no check.
with_variants :: proc(checks: []Gate_Check, dirs: []string, variants: []string) -> []Gate_Check {
	all := make([dynamic]Gate_Check, 0, len(checks) + len(variants), context.temp_allocator)
	append(&all, ..checks)
	for variant in variants {
		if args := strings.trim_space(variant); args != "" {
			append(&all, Gate_Check{dirs = dirs, args = args})
		}
	}
	return all[:]
}

// How the summary and the failures name c: its variant args, or its target, empty for the current one.
gate_label :: proc(c: Gate_Check) -> string {
	return c.args if c.args != "" else c.target
}

// failure, naming the variant or target of c unless it is the plain check on the current target.
gate_failure :: proc(failure: string, c: Gate_Check) -> string {
	if c.args == "" && c.target == "" {
		return failure
	}
	return fmt.tprintf("%s (%s %s)", failure, "with" if c.args != "" else "target", gate_label(c))
}

// The `odin check` errors of checks before the write. On an extra target or a variant, a package whose check
// names an error in a file outside the workspace does not build there: the edit cannot change that file, and odin
// can report a different error set on each run, such as core:os panicking on js_wasm32. The package leaves
// the dirs of that check with a warning, and the check runs again without it, so the after-check compares
// the same packages. Errors in workspace files alone keep the gate, as on the current target.
gate_baseline :: proc(
	checks: []Gate_Check,
	reasons: ^[dynamic]string,
) -> (
	errors: []Check_Error,
	reason: string,
	ok: bool,
) {
	all := make([dynamic]Check_Error, context.temp_allocator)
	for &c, i in checks {
		// A check without a checkable directory leaves no error files behind.
		server.check_run = {}
		found, failure, ran := check_errors(checks[i:i + 1])
		if !ran {
			if skip_refused_windows_check(&c, reasons) do continue
			return {}, failure, false
		}
		if c.target != "" || c.args != "" {
			kept := make([dynamic]string, context.temp_allocator)
			for dir in c.dirs {
				files := server.check_run.error_files[dir]
				if outside, has := outside_error_file(files[:]); has {
					warn(
						reasons,
						fmt.tprintf(
							"%s does not build %s %s: odin check there reports errors in %s, outside the workspace, so the gate does not check it %s",
							workspace_relative(dir),
							"with" if c.args != "" else "on target",
							gate_label(c),
							outside,
							"with those args" if c.args != "" else "on that target",
						),
					)
				} else {
					append(&kept, dir)
				}
			}
			if len(kept) < len(c.dirs) {
				c.dirs = kept[:]
				if found, failure, ran = check_errors(checks[i:i + 1]); !ran {
					return {}, failure, false
				}
			}
		}
		append(&all, ..found)
	}
	return all[:], "", true
}

// Whether gate_baseline skips c after its check failed because odin refused a Windows target: since odin
// dev-2026-10, odin asks for -windows-sdk-root to target Windows on another host, and `odin check` rejects that
// flag. A warning names c, and c keeps no directory, so the check after the write skips it too. The check on the
// current target, whose Windows target comes from checker_args, is not skipped and refuses the edit.
skip_refused_windows_check :: proc(c: ^Gate_Check, reasons: ^[dynamic]string) -> bool {
	if !server.check_run.windows_sdk || (c.target == "" && c.args == "") {
		return false
	}
	warn(
		reasons,
		fmt.tprintf(
			"odin check cannot target Windows on this host: odin asks for -windows-sdk-root, which only odin build takes, so the gate does not check %s %s",
			"with" if c.args != "" else "on target",
			gate_label(c^),
		),
	)
	c.dirs = {}
	return true
}

// The first of files that lies outside the workspace.
@(private = "file")
outside_error_file :: proc(files: []string) -> (file: string, found: bool) {
	for f in files {
		if _, inside := in_workspace(f); !inside {
			return f, true
		}
	}
	return "", false
}
