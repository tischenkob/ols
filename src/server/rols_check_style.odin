package server

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"

// The `type` that merge_style_rerun gives to a style Syntax Error that the rerun did not report. The
// severity of this type is a warning.
STYLE_ERROR_TYPE :: "style"

// The flags that turn a style slip into a Syntax Error, which stops checking.
@(private = "file")
STYLE_FLAGS := [?]string{"-vet-style", "-vet-semicolon", "-vet-tabs", "-strict-style"}

// Whether cmd, an `odin check` command line, has a flag that turns a style slip into a Syntax Error.
style_flags_on :: proc(cmd: []string) -> bool {
	for arg in cmd {
		if slice.contains(STYLE_FLAGS[:], arg) {
			return true
		}
	}
	return false
}

// cmd without the style flags.
without_style_flags :: proc(cmd: []string) -> []string {
	out := make([dynamic]string, 0, len(cmd), context.temp_allocator)
	for arg in cmd {
		if !slice.contains(STYLE_FLAGS[:], arg) {
			append(&out, arg)
		}
	}
	return out[:]
}

// Whether odin reported an error that stops checking: a Syntax Error, or the -vet-tabs finding, which odin
// reports alone as well.
has_stopping_error :: proc(result: Json_Errors) -> bool {
	for error in result.errors {
		if is_stopping_error(error) {
			return true
		}
	}
	return false
}

// Whether a file that a Syntax Error of result names has a syntax error without the style flags: rols' parser
// finds one there. A rerun without the style flags would then stop at it too, so `check` skips the rerun. A file
// that cannot be read counts as clean, which keeps the rerun.
has_real_syntax_error :: proc(result: Json_Errors) -> bool {
	seen := make([dynamic]string, context.temp_allocator)
	for error in result.errors {
		if len(error.msgs) == 0 || !strings.has_prefix(error.msgs[0], "Syntax Error") || error.pos.file == "" {
			continue
		}
		if slice.contains(seen[:], error.pos.file) {
			continue
		}
		append(&seen, error.pos.file)
		data, err := os.read_entire_file(error.pos.file, context.temp_allocator)
		if err == nil && !parses_cleanly(string(data)) {
			return true
		}
	}
	return false
}

// Whether src parses without a syntax error, with the parser flags of an open document.
parses_cleanly :: proc(src: string) -> bool {
	context.allocator = context.temp_allocator
	p := parser.Parser {
		err = proc(pos: tokenizer.Pos, msg: string, args: ..any) {},
		warn = proc(pos: tokenizer.Pos, msg: string, args: ..any) {},
		flags = {.Optional_Semicolons},
	}
	file := ast.File {
		src = src,
	}
	return parser.parse_file(&p, &file) && file.syntax_error_count == 0
}

@(private = "file")
is_stopping_error :: proc(error: Json_Error) -> bool {
	return(
		len(error.msgs) > 0 &&
		(strings.has_prefix(error.msgs[0], "Syntax Error") || strings.has_prefix(error.msgs[0], "With '-vet-tabs'")) \
	)
}

// The errors of a package after the check reran without the style flags. An error of the first run that the
// rerun did not report came from a style flag: it stays, as a warning (type STYLE_ERROR_TYPE),
// beside the errors of the rerun, which has the type errors that the style Syntax Error hid.
merge_style_rerun :: proc(first, rerun: Json_Errors) -> Json_Errors {
	merged := make([dynamic]Json_Error, 0, len(first.errors) + len(rerun.errors), context.temp_allocator)
	append(&merged, ..rerun.errors)
	for error in first.errors {
		if reported_in(rerun.errors, error) {
			continue
		}
		style := error
		style.type = STYLE_ERROR_TYPE
		append(&merged, style)
	}
	return {error_count = len(merged), errors = merged[:]}
}

@(private = "file")
reported_in :: proc(errors: []Json_Error, error: Json_Error) -> bool {
	for other in errors {
		if other.pos.file == error.pos.file &&
		   other.pos.line == error.pos.line &&
		   other.pos.column == error.pos.column &&
		   slice.equal(other.msgs, error.msgs) {
			return true
		}
	}
	return false
}
