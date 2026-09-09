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

@(test)
action_literal_base_round_trips :: proc(t: ^testing.T) {
	hex := literal_source(`package test

main :: proc() {
	x := 0x{*}ff
}
`)

	test.expect_action_round_trip(
		t,
		&hex,
		{"Convert to binary", "Convert to decimal", "Convert to hexadecimal"},
		{"0b1", "255"},
	)

	grouped := literal_source(`package test

main :: proc() {
	x := 0x{*}1_0000
}
`)

	test.expect_action_round_trip(
		t,
		&grouped,
		{"Convert to binary", "Convert to decimal", "Convert to hexadecimal"},
		{"0b1", "65_536"},
	)

	grouping_kept := literal_source(`package test

main :: proc() {
	x := 0x{*}1_0000
}
`)

	test.expect_action_applied(t, &grouping_kept, "Convert to binary", `package test

main :: proc() {
	x := 0b1_0000_0000_0000_0000
}
`)

	zero := literal_source(`package test

main :: proc() {
	x := {*}0
}
`)

	test.expect_action_round_trip(
		t,
		&zero,
		{"Convert to hexadecimal", "Convert to binary", "Convert to decimal"},
		{"0x0", "0b0"},
	)

	one := literal_source(`package test

main :: proc() {
	x := {*}1
}
`)

	test.expect_action_round_trip(
		t,
		&one,
		{"Convert to hexadecimal", "Convert to binary", "Convert to decimal"},
		{"0x1", "0b1"},
	)

	million := literal_source(`package test

main :: proc() {
	x := 1_0{*}00_000
}
`)

	test.expect_action_round_trip(t, &million, {"Convert to hexadecimal", "Convert to decimal"}, {"0xf_4240"})

	widest := literal_source(`package test

main :: proc() {
	x: u64 = 0xff{*}ff_ffff_ffff_ffff
}
`)

	test.expect_action_round_trip(t, &widest, {"Convert to decimal", "Convert to hexadecimal"}, {"18_446_744"})
}

@(test)
action_literal_base_forms :: proc(t: ^testing.T) {
	// Hexadecimal is always rendered in lower case, so an upper-case source does not come back.
	upper := literal_source(`package test

main :: proc() {
	x := 0x{*}FF
}
`)

	test.expect_action_chain(
		t,
		&upper,
		{"Convert to binary", "Convert to decimal", "Convert to hexadecimal"},
		`package test

main :: proc() {
	x := 0xff
}
`,
		{"0b1", "255"},
	)

	octal := literal_source(`package test

main :: proc() {
	x := 0o1{*}7
}
`)

	test.expect_action_chain(
		t,
		&octal,
		{"Convert to decimal", "Convert to hexadecimal", "Convert to decimal"},
		`package test

main :: proc() {
	x := 15
}
`,
		{"15", "0xf"},
	)

	prefixed_decimal := literal_source(`package test

main :: proc() {
	x := 0d1{*}0
}
`)

	test.expect_action_applied(t, &prefixed_decimal, "Convert to decimal", `package test

main :: proc() {
	x := 10
}
`)

	negated := literal_source(`package test

main :: proc() {
	x := -0x{*}FF
}
`)

	test.expect_action_applied(t, &negated, "Convert to decimal", `package test

main :: proc() {
	x := -255
}
`)

	index := literal_source(`package test

main :: proc() {
	xs := []int{1, 2}
	x := xs[0x{*}1]
}
`)

	test.expect_action_applied(t, &index, "Convert to decimal", `package test

main :: proc() {
	xs := []int{1, 2}
	x := xs[1]
}
`)

	case_label := literal_source(`package test

main :: proc() {
	x := 255
	switch x {
	case 0x{*}ff:
		x = 0
	}
}
`)

	test.expect_action_applied(t, &case_label, "Convert to decimal", `package test

main :: proc() {
	x := 255
	switch x {
	case 255:
		x = 0
	}
}
`)

	float := literal_source(`package test

main :: proc() {
	x := 1.{*}5
}
`)

	test.expect_action_missing(t, &float, "Convert to hexadecimal")

	hex_float := literal_source(`package test

main :: proc() {
	x := 0h40{*}10000000000000
}
`)

	test.expect_action_missing(t, &hex_float, "Convert to decimal")

	exponent := literal_source(`package test

main :: proc() {
	x := 1e{*}3
}
`)

	test.expect_action_missing(t, &exponent, "Convert to hexadecimal")
}

@(test)
action_literal_separator_round_trip :: proc(t: ^testing.T) {
	plain := literal_source(`package test

main :: proc() {
	x := 123{*}45
}
`)

	test.expect_action_round_trip(t, &plain, {"Add digit separators", "Remove digit separators"}, {"12_345"})

	// Removing and adding back regroups from the right, so uneven source groups do not survive.
	odd_groups := literal_source(`package test

main :: proc() {
	x := 1_2{*}_3_4_5
}
`)

	test.expect_action_chain(
		t,
		&odd_groups,
		{"Remove digit separators", "Add digit separators"},
		`package test

main :: proc() {
	x := 12_345
}
`,
		{"12345"},
	)

	already_grouped := literal_source(`package test

main :: proc() {
	x := 12_{*}345
}
`)

	test.expect_action_missing(t, &already_grouped, "Add digit separators")
}
