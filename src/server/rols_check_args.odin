package server

import "core:strings"

import "src:common"

// -max-error-count that the compile gate passes: odin stops at 36 errors by default and reports a
// different subset on each run, so the gate asks for all of them.
GATE_MAX_ERROR_COUNT :: "-max-error-count:100000"

// The command line that start_check_process runs: base, the command line that upstream builds before the
// checker_args, then the vet flags of the config and the checker_args words. odin rejects a flag that appears
// twice, so dedupe_flags drops the earlier copy and checker_args wins. style tells that the line has a flag that
// turns a style slip into a Syntax Error, and the rerun drops those flags.
finish_check_command :: proc(
	base: []string,
	config: ^common.Config,
	rerun := false,
) -> (
	command_line: []string,
	style: bool,
) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, ..base)
	if config.enable_checker_vet_shadowing {
		append(&cmd, "-vet-shadowing")
	}
	if config.enable_checker_vet_unused_variables {
		append(&cmd, "-vet-unused-variables")
	}
	if config.enable_checker_vet_cast {
		append(&cmd, "-vet-cast")
	}
	if config.enable_checker_vet_style {
		append(&cmd, "-vet-style")
	}
	if config.enable_checker_vet_semicolon {
		append(&cmd, "-vet-semicolon")
	}
	if config.enable_checker_vet_tabs {
		append(&cmd, "-vet-tabs")
	}
	if config.enable_checker_strict_style {
		append(&cmd, "-strict-style")
	}
	append(&cmd, ..split_checker_args(config.checker_args))
	command_line = dedupe_flags(cmd[:])
	style = style_flags_on(command_line)
	if rerun {
		command_line = without_style_flags(command_line)
	}
	return command_line, style
}

// The checker_args words. Whitespace separates words. A double or single quote opens a group only at the
// start of a word or right after `=` or `:`, and only when a closing quote of the same kind follows. Quotes
// around text with whitespace are removed. Quotes around text without whitespace stay, as the plain split
// on spaces left them: odin reads `-define:NAME="text"` as a value with the quotes in it and strips the
// single quotes of `-define:NAME='text'` itself. Every other quote, such as the apostrophe of
// `-define:MSG=it's`, and every backslash is an ordinary character, so a string without a group splits
// exactly on whitespace.
split_checker_args :: proc(checker_args: string) -> []string {
	words := make([dynamic]string, context.temp_allocator)
	word := strings.builder_make(context.temp_allocator)
	in_word := false
	for i := 0; i < len(checker_args); i += 1 {
		c := checker_args[i]
		if c == '"' || c == '\'' {
			opens := !in_word || checker_args[i - 1] == '=' || checker_args[i - 1] == ':'
			rest := checker_args[i + 1:]
			if end := strings.index_byte(rest, c); opens && end >= 0 {
				in_word = true
				if strings.index_any(rest[:end], " \t\r\n") >= 0 {
					strings.write_string(&word, rest[:end])
				} else {
					strings.write_string(&word, checker_args[i:i + end + 2])
				}
				i += end + 1
				continue
			}
		}
		switch c {
		case ' ', '\t', '\n', '\r':
			if in_word {
				append(&words, strings.to_string(word))
				word = strings.builder_make(context.temp_allocator)
				in_word = false
			}
		case:
			strings.write_byte(&word, c)
			in_word = true
		}
	}
	if in_word {
		append(&words, strings.to_string(word))
	}
	return words[:]
}

// args without a repeated flag: of two flags with one key, the later stays. Arguments that do not start
// with `-` and flags odin accepts repeated stay as they are.
dedupe_flags :: proc(args: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for arg, i in args {
		key := flag_key(arg)
		later := false
		for other in args[i + 1:] {
			if key != "" && flag_key(other) == key {
				later = true
				break
			}
		}
		if !later {
			append(&out, arg)
		}
	}
	return out[:]
}

// The identity of a flag for odin: its name, plus the name before `=` of the -collection and -define value,
// since odin accepts several of them with different names. Empty for an argument that is not a flag.
@(private = "file")
flag_key :: proc(arg: string) -> string {
	// odin accepts these repeated with different values.
	if !strings.has_prefix(arg, "-") ||
	   strings.has_prefix(arg, "-custom-attribute") ||
	   strings.has_prefix(arg, "-sanitize") {
		return ""
	}
	name_end := strings.index_any(arg, ":=")
	if name_end < 0 {
		return arg
	}
	if arg[:name_end] == "-collection" || arg[:name_end] == "-define" {
		value := arg[name_end + 1:]
		if eq := strings.index_byte(value, '='); eq >= 0 {
			return arg[:name_end + 1 + eq]
		}
		return arg
	}
	return arg[:name_end]
}

// config for the compile gate of `ols query … --apply`: the gate wants odin's compile errors, so it
// leaves out the vet and style flags, which turn a style slip into a Syntax Error that stops checking,
// and asks for every error. The collections, defines, entry point flag and checker_args stay. A
// -max-error-count in checker_args stays too.
gate_config :: proc(config: common.Config) -> common.Config {
	gated := config
	gated.enable_checker_vet_shadowing = false
	gated.enable_checker_vet_unused_variables = false
	gated.enable_checker_vet_cast = false
	gated.enable_checker_vet_style = false
	gated.enable_checker_vet_semicolon = false
	gated.enable_checker_vet_tabs = false
	gated.enable_checker_strict_style = false
	gated.profile.checker_path = nil
	gated.enable_diagnostics = true
	if strings.contains(config.checker_args, "-max-error-count") {
		return gated
	}
	gated.checker_args = strings.concatenate({config.checker_args, " ", GATE_MAX_ERROR_COUNT}, context.temp_allocator)
	return gated
}
