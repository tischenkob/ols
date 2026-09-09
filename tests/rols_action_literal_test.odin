package tests

import "core:testing"

import test "src:testing"

// `expect_*` consumes the cursor marker, so every assertion needs its own source.
@(private = "file")
literal_source :: proc(main: string) -> test.Source {
	return test.Source{main = main, config = {enable_code_action_literal = true}}
}

@(test)
action_literal_raw :: proc(t: ^testing.T) {
	interpreted := literal_source(`package test

main :: proc() {
	path := "c:\\a{*}\\b \"x\""
}
`)

	test.expect_action_applied(
		t,
		&interpreted,
		"Convert to raw string",
		"package test\n\nmain :: proc() {\n\tpath := `c:\\a\\b \"x\"`\n}\n",
	)

	raw := literal_source("package test\n\nmain :: proc() {\n\tpath := `c:\\a{*}\\b \"x\"`\n}\n")

	test.expect_action_applied(
		t,
		&raw,
		"Convert to interpreted string",
		`package test

main :: proc() {
	path := "c:\\a\\b \"x\""
}
`,
	)

	has_backtick := literal_source(`package test

main :: proc() {
	s := "a` + "`" + `b{*}"
}
`)

	test.expect_action_missing(t, &has_backtick, "Convert to raw string")

	has_newline_escape := literal_source(`package test

main :: proc() {
	s := "a\nb{*}"
}
`)

	test.expect_action_missing(t, &has_newline_escape, "Convert to raw string")
}

@(test)
action_literal_base :: proc(t: ^testing.T) {
	DECIMAL :: `package test

main :: proc() {
	x := 25{*}5
}
`
	to_hex := literal_source(DECIMAL)

	test.expect_action_applied(t, &to_hex, "Convert to hexadecimal", `package test

main :: proc() {
	x := 0xff
}
`)

	to_binary := literal_source(DECIMAL)

	test.expect_action_applied(
		t,
		&to_binary,
		"Convert to binary",
		`package test

main :: proc() {
	x := 0b11111111
}
`,
	)

	already_decimal := literal_source(DECIMAL)

	test.expect_action_missing(t, &already_decimal, "Convert to decimal")

	HEX :: `package test

main :: proc() {
	x := 0xdead_beef{*}
}
`
	hex_to_decimal := literal_source(HEX)

	// The source groups its digits, so the conversion keeps groups too.
	test.expect_action_applied(
		t,
		&hex_to_decimal,
		"Convert to decimal",
		`package test

main :: proc() {
	x := 3_735_928_559
}
`,
	)

	already_hex := literal_source(HEX)

	test.expect_action_missing(t, &already_hex, "Convert to hexadecimal")

	binary := literal_source(`package test

main :: proc() {
	x := 0b1{*}0110
}
`)

	test.expect_action_applied(t, &binary, "Convert to hexadecimal", `package test

main :: proc() {
	x := 0x16
}
`)
}

@(test)
action_literal_separators :: proc(t: ^testing.T) {
	plain := literal_source(`package test

main :: proc() {
	x := 1234{*}567
}
`)

	test.expect_action_applied(t, &plain, "Add digit separators", `package test

main :: proc() {
	x := 1_234_567
}
`)

	grouped := literal_source(`package test

main :: proc() {
	x := 1_234{*}_567
}
`)

	test.expect_action_applied(
		t,
		&grouped,
		"Remove digit separators",
		`package test

main :: proc() {
	x := 1234567
}
`,
	)

	short := literal_source(`package test

main :: proc() {
	x := 12{*}34
}
`)

	test.expect_action_missing(t, &short, "Add digit separators")
}
