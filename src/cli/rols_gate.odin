package cli

import "core:fmt"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
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

// The `-target:` values the gate checks with, the current target first as an empty string. The others
// are the targets that checker_targets names and a target for each file that the current one does not
// build: a touched file, or any file of an importer directory that has no file for the current target.
// Before and after the write use the same list. A touched file that no target builds gets a warning.
gate_targets :: proc(changed: []File_State, importers: []string, reasons: ^[dynamic]string) -> []string {
	config := &common.config
	targets := make([dynamic]string, context.temp_allocator)
	append(&targets, "")
	base := server.base_target(config.checker_args)

	extra := make([dynamic]string, context.temp_allocator)
	for entry in config.checker_targets {
		if name, ok := server.target_name(entry); ok {
			append(&extra, name)
		} else {
			warn(reasons, fmt.tprintf("checker_targets: %q is not an odin target; skipped", entry))
		}
	}
	note :: proc(extra: ^[dynamic]string, reasons: ^[dynamic]string, name, text: string, base: parser.Build_Target) {
		switch target, need := server.target_for_file(name, text, base); need {
		case .None:
		case .Other:
			append(extra, target)
		case .Nowhere:
			if reasons != nil {
				warn(
					reasons,
					fmt.tprintf("%s builds on no target the gate knows, so the gate does not check it", name),
				)
			}
		}
	}
	for file in changed {
		if filepath.ext(file.path) != ".odin" {
			continue
		}
		// The edit can add or drop a tag, so the old and the new text both count.
		if file.existed && (!file.exists || file.original != file.text) {
			note(&extra, reasons, file.path, file.original, base)
		}
		if file.exists {
			note(&extra, reasons, file.path, file.text, base)
		}
	}
	for dir in importers {
		matches, _ := filepath.glob(
			strings.concatenate({dir, "/*.odin"}, context.temp_allocator),
			context.temp_allocator,
		)
		texts := make([]string, len(matches), context.temp_allocator)
		built := false
		for match, i in matches {
			data, err := os.read_entire_file(match, context.temp_allocator)
			if err == nil {
				texts[i] = string(data)
				built ||= server.builds_on(match, texts[i], base)
			}
		}
		if !built {
			for match, i in matches {
				note(&extra, nil, match, texts[i], base)
			}
		}
	}
	slice.sort(extra[:])
	for target in slice.unique(extra[:]) {
		if parsed, _ := server.parse_target(target); parsed != base {
			append(&targets, target)
		}
	}
	return targets[:]
}

// The package directories that the gate checks with one `-target:` value, empty for the current target,
// and the extra checker args of a checker_variants entry, empty for none.
Gate_Check :: struct {
	target: string,
	dirs:   []string,
	args:   string,
}

// checks followed by one check of dirs on the current target for each checker_variants entry. An entry of
// only whitespace adds no check.
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

// How the summary and the failures name check: its target, its variant args, or both. Empty for the plain
// check on the current target.
gate_label :: proc(c: Gate_Check) -> string {
	if c.args == "" {
		return c.target
	}
	return c.args if c.target == "" else fmt.tprintf("%s %s", c.target, c.args)
}

// failure, naming the target or variant of c unless it is the plain check on the current target.
gate_failure :: proc(failure: string, c: Gate_Check) -> string {
	switch {
	case c.args != "":
		return fmt.tprintf("%s (with %s)", failure, gate_label(c))
	case c.target != "":
		return fmt.tprintf("%s (target %s)", failure, c.target)
	}
	return failure
}

// The `odin check` errors of checks before the write. On an extra target, a package whose check names an
// error in a file outside the workspace does not build there: the edit cannot change that file, and odin
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
			return {}, failure, false
		}
		if c.target != "" {
			kept := make([dynamic]string, context.temp_allocator)
			for dir in c.dirs {
				files := server.check_run.error_files[dir]
				if outside, has := outside_error_file(files[:]); has {
					warn(
						reasons,
						fmt.tprintf(
							"%s does not build on target %s: odin check there reports errors in %s, outside the workspace, so the gate does not check it on that target",
							workspace_relative(dir),
							c.target,
							outside,
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
