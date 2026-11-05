package tests

import "core:testing"

import test "src:testing"

@(private = "file")
expect_applied :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_range_loop = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

@(private = "file")
expect_missing :: proc(t: ^testing.T, title, main: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_range_loop = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(private = "file")
expect_needs_flag :: proc(t: ^testing.T, title, main: string) {
	source := test.Source {
		main = main,
	}
	test.expect_action_missing(t, &source, title)
}

@(private = "file")
HEAD :: `package test

Color :: enum {
	A,
	B,
}

It :: struct {
	n: int,
}

iter :: proc(it: ^It) -> (int, bool) {
	return 0, false
}

items :: proc() -> []int {
	return nil
}

f :: proc(xs: []int, arr: [3]int, str: string, m: map[int]int, pa: ^[3]int) {
`

@(test)
range_loop_add_index :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Add index",
		HEAD + `	{*}for x in xs {
		use(x)
	}
}
`,
		HEAD + `	for x, i in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_add_index_cursor_on_iterable :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Add index",
		HEAD + `	for x in {*}str {
		use(x)
	}
}
`,
		HEAD + `	for x, i in str {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_add_index_integer_range :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Add index",
		HEAD + `	{*}for x in 0..<3 {
		use(x)
	}
}
`,
		HEAD + `	for x, i in 0..<3 {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_add_index_enum :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Add index",
		HEAD + `	{*}for x in Color {
		use(x)
	}
}
`,
		HEAD + `	for x, i in Color {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_add_index_call_with_one_result :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Add index",
		HEAD + `	{*}for x in items() {
		use(x)
	}
}
`,
		HEAD + `	for x, i in items() {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_add_index_by_reference :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Add index",
		HEAD + `	{*}for &x in xs {
		x = 1
	}
}
`,
		HEAD + `	for &x, i in xs {
		x = 1
	}
}
`,
	)
}

@(test)
range_loop_add_index_avoids_outer_name :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Add index",
		HEAD + `	i := 1
	{*}for x in xs {
		use(x, i)
	}
}
`,
		HEAD + `	i := 1
	for x, i2 in xs {
		use(x, i)
	}
}
`,
	)
}

@(test)
range_loop_add_index_avoids_name_in_body :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Add index",
		HEAD + `	{*}for x in xs {
		i := x
		use(i)
	}
}
`,
		HEAD + `	for x, j in xs {
		i := x
		use(i)
	}
}
`,
	)
}

@(test)
range_loop_add_index_avoids_value_name :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Add index",
		HEAD + `	{*}for i in xs {
		use(i)
	}
}
`,
		HEAD + `	for i, j in xs {
		use(i)
	}
}
`,
	)
}

@(test)
range_loop_add_index_refuses_map :: proc(t: ^testing.T) {
	expect_missing(t, "Add index", HEAD + `	{*}for k in m {
		use(k)
	}
}
`)
}

@(test)
range_loop_add_index_refuses_two_values :: proc(t: ^testing.T) {
	expect_missing(t, "Add index", HEAD + `	{*}for x, y in xs {
		use(x, y)
	}
}
`)
}

@(test)
range_loop_add_index_refuses_iterator :: proc(t: ^testing.T) {
	expect_missing(t, "Add index", HEAD + `	it: It
	{*}for x in iter(&it) {
		use(x)
	}
}
`)
}

@(test)
range_loop_add_index_refuses_bit_set :: proc(t: ^testing.T) {
	expect_missing(t, "Add index", HEAD + `	b: bit_set[Color]
	{*}for x in b {
		use(x)
	}
}
`)
}

@(test)
range_loop_add_index_refuses_cursor_in_body :: proc(t: ^testing.T) {
	expect_missing(t, "Add index", HEAD + `	for x in xs {
		use({*}x)
	}
}
`)
}

@(test)
range_loop_add_index_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(
		t,
		"Add index",
		`package test

Color :: enum {
	A,
	B,
}

It :: struct {
	n: int,
}

iter :: proc(it: ^It) -> (int, bool) {
	return 0, false
}

items :: proc() -> []int {
	return nil
}

f :: proc(xs: []int, arr: [3]int, str: string, m: map[int]int, pa: ^[3]int) {
	{*}for x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_by_reference :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Iterate by reference",
		HEAD + `	{*}for x in xs {
		use(x)
	}
}
`,
		HEAD + `	for &x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_by_reference_two_values :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Iterate by reference",
		HEAD + `	{*}for x, i in xs {
		use(x, i)
	}
}
`,
		HEAD + `	for &x, i in xs {
		use(x, i)
	}
}
`,
	)
}

@(test)
range_loop_by_reference_local_array :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Iterate by reference",
		HEAD + `	a: [3]int
	{*}for x in a {
		use(x)
	}
}
`,
		HEAD + `	a: [3]int
	for &x in a {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_by_reference_array_pointer :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Iterate by reference",
		HEAD + `	{*}for x in pa {
		use(x)
	}
}
`,
		HEAD + `	for &x in pa {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_by_reference_call_slice :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Iterate by reference",
		HEAD + `	{*}for x in items() {
		use(x)
	}
}
`,
		HEAD + `	for &x in items() {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_by_reference_refuses_array_parameter :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by reference", HEAD + `	{*}for x in arr {
		use(x)
	}
}
`)
}

@(test)
range_loop_by_reference_refuses_string :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by reference", HEAD + `	{*}for x in str {
		use(x)
	}
}
`)
}

@(test)
range_loop_by_reference_refuses_range :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by reference", HEAD + `	{*}for x in 0..<3 {
		use(x)
	}
}
`)
}

@(test)
range_loop_by_reference_refuses_map :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by reference", HEAD + `	{*}for k, v in m {
		use(k, v)
	}
}
`)
}

@(test)
range_loop_by_reference_refuses_iterator :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by reference", HEAD + `	it: It
	{*}for x in iter(&it) {
		use(x)
	}
}
`)
}

@(test)
range_loop_by_reference_refuses_blank :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by reference", HEAD + `	{*}for _ in xs {
	}
}
`)
}

@(test)
range_loop_by_reference_refuses_body_naming_iterable :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by reference", HEAD + `	{*}for x in xs {
		xs[0] = 2
		use(x)
	}
}
`)
}

@(test)
range_loop_by_reference_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(
		t,
		"Iterate by reference",
		`package test

Color :: enum {
	A,
	B,
}

It :: struct {
	n: int,
}

iter :: proc(it: ^It) -> (int, bool) {
	return 0, false
}

items :: proc() -> []int {
	return nil
}

f :: proc(xs: []int, arr: [3]int, str: string, m: map[int]int, pa: ^[3]int) {
	{*}for x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_by_value :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Iterate by value",
		HEAD + `	{*}for &x in xs {
		use(x)
	}
}
`,
		HEAD + `	for x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_by_value_two_values :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Iterate by value",
		HEAD + `	{*}for &x, i in xs {
		use(x, i)
	}
}
`,
		HEAD + `	for x, i in xs {
		use(x, i)
	}
}
`,
	)
}

@(test)
range_loop_by_value_refuses_write :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by value", HEAD + `	{*}for &x in xs {
		x = 1
	}
}
`)
}

@(test)
range_loop_by_value_refuses_compound_write :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by value", HEAD + `	{*}for &x in xs {
		x += 1
	}
}
`)
}

@(test)
range_loop_by_value_refuses_field_write :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by value", HEAD + `	ss: []It
	{*}for &x in ss {
		x.n = 1
	}
}
`)
}

@(test)
range_loop_by_value_refuses_address :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by value", HEAD + `	{*}for &x in xs {
		use(&x)
	}
}
`)
}

@(test)
range_loop_by_value_refuses_slice_of_element :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by value", HEAD + `	aa: [][3]int
	{*}for &x in aa {
		use(x[:])
	}
}
`)
}

@(test)
range_loop_by_value_refuses_method :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by value", HEAD + `	ss: []It
	{*}for &x in ss {
		x->go()
	}
}
`)
}

@(test)
range_loop_by_value_refuses_body_naming_iterable :: proc(t: ^testing.T) {
	expect_missing(t, "Iterate by value", HEAD + `	{*}for &x in xs {
		xs[0] = 2
		use(x)
	}
}
`)
}

@(test)
range_loop_by_value_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(
		t,
		"Iterate by value",
		`package test

Color :: enum {
	A,
	B,
}

It :: struct {
	n: int,
}

iter :: proc(it: ^It) -> (int, bool) {
	return 0, false
}

items :: proc() -> []int {
	return nil
}

f :: proc(xs: []int, arr: [3]int, str: string, m: map[int]int, pa: ^[3]int) {
	{*}for &x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_reverse_adds :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Toggle #reverse",
		HEAD + `	{*}for x in xs {
		use(x)
	}
}
`,
		HEAD + `	#reverse for x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_reverse_adds_after_label :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Toggle #reverse",
		HEAD + `	outer: {*}for x in xs {
		use(x)
	}
}
`,
		HEAD + `	outer: #reverse for x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_reverse_adds_string :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Toggle #reverse",
		HEAD + `	{*}for x in str {
		use(x)
	}
}
`,
		HEAD + `	#reverse for x in str {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_reverse_adds_bit_set :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Toggle #reverse",
		HEAD + `	b: bit_set[Color]
	{*}for x in b {
		use(x)
	}
}
`,
		HEAD + `	b: bit_set[Color]
	#reverse for x in b {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_reverse_removes :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Toggle #reverse",
		HEAD + `	#reverse {*}for x in xs {
		use(x)
	}
}
`,
		HEAD + `	for x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_reverse_removes_cursor_on_directive :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Toggle #reverse",
		HEAD + `	{*}#reverse for x in xs {
		use(x)
	}
}
`,
		HEAD + `	for x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_reverse_removes_before_label :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Toggle #reverse",
		HEAD + `	#reverse outer: {*}for x in xs {
		use(x)
	}
}
`,
		HEAD + `	outer: for x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_reverse_refuses_map :: proc(t: ^testing.T) {
	expect_missing(t, "Toggle #reverse", HEAD + `	{*}for k in m {
		use(k)
	}
}
`)
}

@(test)
range_loop_reverse_refuses_range :: proc(t: ^testing.T) {
	expect_missing(t, "Toggle #reverse", HEAD + `	{*}for x in 0..<3 {
		use(x)
	}
}
`)
}

@(test)
range_loop_reverse_refuses_enum :: proc(t: ^testing.T) {
	expect_missing(t, "Toggle #reverse", HEAD + `	{*}for x in Color {
		use(x)
	}
}
`)
}

@(test)
range_loop_reverse_refuses_iterator :: proc(t: ^testing.T) {
	expect_missing(t, "Toggle #reverse", HEAD + `	it: It
	{*}for x in iter(&it) {
		use(x)
	}
}
`)
}

@(test)
range_loop_reverse_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(
		t,
		"Toggle #reverse",
		`package test

Color :: enum {
	A,
	B,
}

It :: struct {
	n: int,
}

iter :: proc(it: ^It) -> (int, bool) {
	return 0, false
}

items :: proc() -> []int {
	return nil
}

f :: proc(xs: []int, arr: [3]int, str: string, m: map[int]int, pa: ^[3]int) {
	{*}for x in xs {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_range_half_to_full :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to ..= range",
		HEAD + `	{*}for x in 0..<10 {
		use(x)
	}
}
`,
		HEAD + `	for x in 0..=9 {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_range_full_to_half :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to ..< range",
		HEAD + `	{*}for x in 0..=9 {
		use(x)
	}
}
`,
		HEAD + `	for x in 0..<10 {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_range_keeps_spaces :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to ..= range",
		HEAD + `	{*}for x in 0 ..< 10 {
		use(x)
	}
}
`,
		HEAD + `	for x in 0 ..= 9 {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_range_typed_start :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to ..< range",
		HEAD + `	lo: u8
	{*}for x in lo..=254 {
		use(x)
	}
}
`,
		HEAD + `	lo: u8
	for x in lo..<255 {
		use(x)
	}
}
`,
	)
}

@(test)
range_loop_range_refuses_name_end :: proc(t: ^testing.T) {
	expect_missing(t, "Convert to ..= range", HEAD + `	n := 3
	{*}for x in 0..<n {
		use(x)
	}
}
`)
}

@(test)
range_loop_range_refuses_expression_end :: proc(t: ^testing.T) {
	expect_missing(t, "Convert to ..< range", HEAD + `	n := 3
	{*}for x in 0..=n + 1 {
		use(x)
	}
}
`)
}

@(test)
range_loop_range_refuses_hex_end :: proc(t: ^testing.T) {
	expect_missing(t, "Convert to ..= range", HEAD + `	{*}for x in 0..<0x10 {
		use(x)
	}
}
`)
}

@(test)
range_loop_range_refuses_zero_end :: proc(t: ^testing.T) {
	expect_missing(t, "Convert to ..= range", HEAD + `	lo := -2
	{*}for x in lo..<0 {
		use(x)
	}
}
`)
}

@(test)
range_loop_range_refuses_float_start :: proc(t: ^testing.T) {
	expect_missing(t, "Convert to ..= range", HEAD + `	{*}for x in 0.5..<3 {
		use(x)
	}
}
`)
}

@(test)
range_loop_range_refuses_float_variable_start :: proc(t: ^testing.T) {
	expect_missing(t, "Convert to ..= range", HEAD + `	lo: f32
	{*}for x in lo..<3 {
		use(x)
	}
}
`)
}

@(test)
range_loop_range_refuses_end_past_type :: proc(t: ^testing.T) {
	expect_missing(t, "Convert to ..< range", HEAD + `	lo: u8
	{*}for x in lo..=255 {
		use(x)
	}
}
`)
}

@(test)
range_loop_range_needs_flag :: proc(t: ^testing.T) {
	expect_needs_flag(
		t,
		"Convert to ..= range",
		`package test

Color :: enum {
	A,
	B,
}

It :: struct {
	n: int,
}

iter :: proc(it: ^It) -> (int, bool) {
	return 0, false
}

items :: proc() -> []int {
	return nil
}

f :: proc(xs: []int, arr: [3]int, str: string, m: map[int]int, pa: ^[3]int) {
	{*}for x in 0..<10 {
		use(x)
	}
}
`,
	)
}
