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
