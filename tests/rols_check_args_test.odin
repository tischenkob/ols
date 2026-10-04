package tests

import "core:slice"
import "core:testing"

import "src:common"
import "src:server"

@(test)
check_command_drops_duplicate_entry_point_flag :: proc(t: ^testing.T) {
	config := common.Config {
		checker_args = "-no-entry-point  -json-errors",
	}
	cmd := server.check_command("pkg/", nil, &config)
	testing.expect_value(t, slice.count(cmd, "-no-entry-point"), 1)
	testing.expect_value(t, slice.count(cmd, "-json-errors"), 1)
	testing.expect(t, slice.equal(cmd[:3], []string{"odin", "check", "pkg/"}))
}

@(test)
check_command_user_define_and_collection_win :: proc(t: ^testing.T) {
	defines := make(map[string]string, context.temp_allocator)
	defines["A"] = "profile"
	defines["B"] = "keep"
	config := common.Config {
		profile      = {defines = defines},
		checker_args = "-define:A=user -collection:x=/user",
	}
	cmd := server.check_command("pkg/", {"-collection:x=/profile", "-collection:y=/y"}, &config)
	testing.expect(t, slice.contains(cmd, "-define:A=user"))
	testing.expect(t, !slice.contains(cmd, "-define:A=profile"))
	testing.expect(t, slice.contains(cmd, "-define:B=keep"))
	testing.expect(t, slice.contains(cmd, "-collection:x=/user"))
	testing.expect(t, !slice.contains(cmd, "-collection:x=/profile"))
	testing.expect(t, slice.contains(cmd, "-collection:y=/y"))
}

@(test)
check_command_vet_flag_in_args_and_config_is_one :: proc(t: ^testing.T) {
	config := common.Config {
		enable_checker_vet_style = true,
		checker_args             = "-vet-style",
	}
	cmd := server.check_command("pkg/", nil, &config)
	testing.expect_value(t, slice.count(cmd, "-vet-style"), 1)
}

@(test)
check_command_uses_file_flag_for_a_file :: proc(t: ^testing.T) {
	config: common.Config
	cmd := server.check_command("a.odin", nil, &config)
	testing.expect_value(t, slice.count(cmd, "-file"), 1)
	testing.expect_value(t, slice.count(cmd, "-no-entry-point"), 0)
}

@(test)
gate_config_drops_vet_flags_and_asks_for_every_error :: proc(t: ^testing.T) {
	config := common.Config {
		enable_checker_vet_shadowing         = true,
		enable_checker_vet_unused_variables  = true,
		enable_checker_vet_cast              = true,
		enable_checker_vet_style             = true,
		enable_checker_vet_semicolon         = true,
		enable_checker_vet_tabs              = true,
		enable_checker_strict_style          = true,
		checker_args                         = "-no-entry-point -vet-style",
	}
	gated := server.gate_config(config)
	cmd := server.check_command("pkg/", nil, &gated)
	for flag in ([?]string {
			"-vet-shadowing", "-vet-unused-variables", "-vet-cast", "-vet-semicolon", "-vet-tabs", "-strict-style",
		}) {
		testing.expect_value(t, slice.count(cmd, flag), 0)
	}
	// The user's own checker_args stay, repeated flags included once.
	testing.expect_value(t, slice.count(cmd, "-vet-style"), 1)
	testing.expect_value(t, slice.count(cmd, "-no-entry-point"), 1)
	testing.expect_value(t, slice.count(cmd, server.GATE_MAX_ERROR_COUNT), 1)
	// The caller's config stays as it was.
	testing.expect(t, config.enable_checker_vet_style)
	testing.expect_value(t, config.checker_args, "-no-entry-point -vet-style")
}

@(test)
gate_config_keeps_the_max_error_count_of_the_user :: proc(t: ^testing.T) {
	config := common.Config {
		checker_args = "-max-error-count:5",
	}
	gated := server.gate_config(config)
	cmd := server.check_command("pkg/", nil, &gated)
	testing.expect_value(t, slice.count(cmd, "-max-error-count:5"), 1)
	testing.expect_value(t, slice.count(cmd, server.GATE_MAX_ERROR_COUNT), 0)
}

@(test)
test_command_drops_duplicate_flags :: proc(t: ^testing.T) {
	config := common.Config {
		checker_args = "-define:ODIN_TEST_FANCY=true -vet",
	}
	cmd := server.test_command("pkg", "", &config)
	testing.expect_value(t, slice.count(cmd, "-define:ODIN_TEST_FANCY=false"), 1)
	testing.expect_value(t, slice.count(cmd, "-define:ODIN_TEST_FANCY=true"), 0)
	testing.expect_value(t, slice.count(cmd, "-vet"), 1)
}

@(test)
check_command_keeps_repeatable_flags :: proc(t: ^testing.T) {
	config := common.Config {
		checker_args = "-custom-attribute:a -custom-attribute:b -sanitize:address -sanitize:memory",
	}
	cmd := server.check_command("pkg/", nil, &config)
	testing.expect_value(t, slice.count(cmd, "-custom-attribute:a"), 1)
	testing.expect_value(t, slice.count(cmd, "-custom-attribute:b"), 1)
	testing.expect_value(t, slice.count(cmd, "-sanitize:address"), 1)
	testing.expect_value(t, slice.count(cmd, "-sanitize:memory"), 1)
}

@(test)
split_checker_args_groups_quoted_values :: proc(t: ^testing.T) {
	words := server.split_checker_args(`-a  -collection:x="/my path"  '-b c' -d="e f"g -w=C:\libs\x -h\ i "it's a b"`)
	want := []string{"-a", "-collection:x=/my path", "-b c", "-d=e fg", `-w=C:\libs\x`, `-h\`, "i", "it's a b"}
	testing.expect(t, slice.equal(words, want), "split into the wrong words")
}

@(test)
split_checker_args_splits_on_whitespace_without_a_closed_group :: proc(t: ^testing.T) {
	words := server.split_checker_args(`-a -collection:x="/my path -b`)
	testing.expect(t, slice.equal(words, []string{"-a", `-collection:x="/my`, "path", "-b"}))
	words = server.split_checker_args(`-a 'b c`)
	testing.expect(t, slice.equal(words, []string{"-a", "'b", "c"}))
	words = server.split_checker_args("-define:MSG=it's -vet")
	testing.expect(t, slice.equal(words, []string{"-define:MSG=it's", "-vet"}))
	words = server.split_checker_args("-define:A=it's -define:B=can't")
	testing.expect(t, slice.equal(words, []string{"-define:A=it's", "-define:B=can't"}))
	words = server.split_checker_args("-a\t-b\n-c")
	testing.expect(t, slice.equal(words, []string{"-a", "-b", "-c"}))
	testing.expect_value(t, len(server.split_checker_args("  \t ")), 0)
}

@(test)
check_command_passes_a_quoted_collection_path_as_one_argument :: proc(t: ^testing.T) {
	config := common.Config {
		checker_args = `-collection:x="/my path"`,
	}
	cmd := server.check_command("pkg/", nil, &config)
	testing.expect_value(t, slice.count(cmd, "-collection:x=/my path"), 1)
}

@(test)
split_checker_args_keeps_quotes_without_whitespace :: proc(t: ^testing.T) {
	words := server.split_checker_args(`-define:T="hello" -define:U='x' "" -define:V="a b"`)
	want := []string{`-define:T="hello"`, `-define:U='x'`, `""`, "-define:V=a b"}
	testing.expect(t, slice.equal(words, want), "quotes around text without whitespace must stay")
}
