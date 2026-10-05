package tests

import "core:testing"

import test "src:testing"

@(private = "file")
SHAPES :: `package test

POINT_RADIUS :: 1

Kind :: enum {
	NONE,
	CIRCLE,
	AABB,
}

Circle :: struct {
	radius: f32,
}

Rect :: struct {
	w: f32,
}

Shape :: union {
	Circle,
	Rect,
}
`

@(test)
lint_redundant_type_assertion_reports :: proc(t: ^testing.T) {
	source := test.Source {
		main = SHAPES +
		`
payload :: proc "contextless" (s: ^Shape) -> (rawptr, Kind) {
	switch _ in s {
	case Circle:
		c := &s.(Circle)
		if c.radius <= 0 {
			c.radius = POINT_RADIUS
		}
		return c, .CIRCLE
	case Rect:
		return &s.(Rect), .AABB
	}
	return nil, .NONE
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{26, "redundant-type-assertion"}, {32, "redundant-type-assertion"}},
		{"`s` is already `Circle` in this case; bind it in the switch"},
	)
}

@(test)
lint_redundant_type_assertion_skips :: proc(t: ^testing.T) {
	source := test.Source {
		main = SHAPES +
		`
many :: proc(s: Shape) -> f32 {
	switch _ in s {
	case Circle, Rect:
		return 0
	case:
		return s.(Circle).radius
	}
	return 0
}

other :: proc(s: Shape) -> f32 {
	switch _ in s {
	case Rect:
		return s.(Circle).radius
	}
	return 0
}

checked :: proc(s: Shape) -> f32 {
	switch _ in s {
	case Circle:
		c, ok := s.(Circle)
		if ok do return c.radius
	}
	return 0
}

written :: proc(s: Shape) -> f32 {
	s := s
	switch _ in s {
	case Circle:
		s = Rect{}
		return s.(Circle).radius
	}
	return 0
}

shadowed :: proc(s: Shape) -> f32 {
	switch _ in s {
	case Circle:
		{
			s := Shape(Rect{})
			_ = s
		}
		return s.(Circle).radius
	}
	return 0
}

grow :: proc(s: ^Shape) {}

passed_on :: proc(s: ^Shape) -> f32 {
	switch _ in s {
	case Circle:
		grow(s)
		return s.(Circle).radius
	}
	return 0
}

optional_ok :: proc(s: Shape) -> (Circle, bool) {
	switch _ in s {
	case Circle:
		return s.(Circle)
	}
	return {}, false
}

nested :: proc(s: Shape) -> f32 {
	switch _ in s {
	case Circle:
		switch _ in s {
		case Circle:
			return s.(Circle).radius
		}
	}
	return 0
}

defaulted :: proc(s: Shape) -> Circle {
	switch _ in s {
	case Circle:
		return s.(Circle) or_else {}
	}
	return {}
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	// Only the inner switch of `nested` is reported.
	test.expect_lint_diagnostics(t, &source, {{96, "redundant-type-assertion"}})
}

@(test)
lint_redundant_type_assertion_off :: proc(t: ^testing.T) {
	FN :: `
f :: proc(s: Shape) -> f32 {
	switch _ in s {
	case Circle:
		return s.(Circle).radius
	}
	return 0
}
`
	source := test.Source {
		main = SHAPES + FN,
	}
	test.expect_lint_diagnostics(t, &source, {})

	action_source := test.Source {
		main = SHAPES + `
f :: proc(s: Shape) -> f32 {
	switch _ in s{*} {
	case Circle:
		return s.(Circle).radius
	}
	return 0
}
`,
	}
	test.expect_action_missing(t, &action_source, "Bind the switch variant")
}

@(test)
bind_switch_payload :: proc(t: ^testing.T) {
	source := test.Source {
		main = SHAPES +
		`
payload :: proc "contextless" (s: ^Shape) -> (rawptr, Kind) {
	switch _ in s{*} {
	case Circle:
		c := &s.(Circle)
		if c.radius <= 0 {
			c.radius = POINT_RADIUS
		}
		return c, .CIRCLE
	case Rect:
		return &s.(Rect), .AABB
	}
	return nil, .NONE
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Bind the switch variant",
		SHAPES +
		`
payload :: proc "contextless" (s: ^Shape) -> (rawptr, Kind) {
	switch &v in s {
	case Circle:
		if v.radius <= 0 {
			v.radius = POINT_RADIUS
		}
		return &v, .CIRCLE
	case Rect:
		return &v, .AABB
	}
	return nil, .NONE
}
`,
	)
}

@(test)
bind_switch_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = SHAPES +
		`
f :: proc(s: Shape) -> f32 {
	switch in s {
	case Circle:
		c := s.(Circle)
		return c.radius + s.({*}Circle).radius
	case Rect:
		return s.(Rect).w
	}
	return 0
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Bind the switch variant",
		SHAPES +
		`
f :: proc(s: Shape) -> f32 {
	switch v in s {
	case Circle:
		return v.radius + v.radius
	case Rect:
		return v.w
	}
	return 0
}
`,
	)
}

@(test)
bind_switch_named :: proc(t: ^testing.T) {
	source := test.Source {
		main = SHAPES +
		`
f :: proc(s: ^Shape) {
	switch x{*} in s {
	case Circle:
		_ = x
		s.(Circle).radius = 2
	}
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Bind the switch variant",
		SHAPES + `
f :: proc(s: ^Shape) {
	switch &x in s {
	case Circle:
		_ = x
		x.radius = 2
	}
}
`,
	)
}

@(test)
bind_switch_fresh_name_and_kept_alias :: proc(t: ^testing.T) {
	source := test.Source {
		main = SHAPES +
		`
f :: proc(s: ^Shape, other: ^Circle) -> f32 {
	switch _ in s{*} {
	case Circle:
		v := 1
		c := &s.(Circle)
		if v > 0 do c = other
		return c.radius
	}
	return 0
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Bind the switch variant",
		SHAPES +
		`
f :: proc(s: ^Shape, other: ^Circle) -> f32 {
	switch &v2 in s {
	case Circle:
		v := 1
		c := &v2
		if v > 0 do c = other
		return c.radius
	}
	return 0
}
`,
	)
}

@(test)
bind_switch_keeps_copy_when_binding_written :: proc(t: ^testing.T) {
	source := test.Source {
		main = SHAPES +
		`
use :: proc(f: f32) {}

f :: proc(s: ^Shape) {
	switch &x{*} in s {
	case Circle:
		old := s.(Circle)
		x.radius = 2
		use(old.radius)
	case Rect:
	}
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Bind the switch variant",
		SHAPES +
		`
use :: proc(f: f32) {}

f :: proc(s: ^Shape) {
	switch &x in s {
	case Circle:
		old := x
		x.radius = 2
		use(old.radius)
	case Rect:
	}
}
`,
	)
}

@(test)
bind_switch_slice_and_deref :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Bytes :: union {
	[4]u8,
	int,
}

take :: proc(b: []u8) {}

f :: proc(s: ^Bytes) -> int {
	switch _ in s{*} {
	case [4]u8:
		take(s.([4]u8)[:])
	case int:
		p := &s.(int)
		return p^
	}
	return 0
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Bind the switch variant",
		`package test

Bytes :: union {
	[4]u8,
	int,
}

take :: proc(b: []u8) {}

f :: proc(s: ^Bytes) -> int {
	switch &v in s {
	case [4]u8:
		take(v[:])
	case int:
		return v
	}
	return 0
}
`,
	)
}

@(test)
bind_switch_pointer_variant_by_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Ident :: struct {
	name: string,
}

Call :: struct {
	args: int,
}

Node :: union {
	^Ident,
	^Call,
}

rename :: proc(n: Node) {
	switch _ in n{*} {
	case ^Ident:
		n.(^Ident).name = "x"
	case ^Call:
	}
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Bind the switch variant",
		`package test

Ident :: struct {
	name: string,
}

Call :: struct {
	args: int,
}

Node :: union {
	^Ident,
	^Call,
}

rename :: proc(n: Node) {
	switch v in n {
	case ^Ident:
		v.name = "x"
	case ^Call:
	}
}
`,
	)

	named := test.Source {
		main = `package test

Ident :: struct {
	name: string,
}

Node :: union {
	^Ident,
	int,
}

named :: proc(n: Node) {
	switch x{*} in n {
	case ^Ident:
		x.name = "y"
		n.(^Ident).name = "z"
	case int:
	}
}
`,
		config = {enable_lint_redundant_type_assertion = true},
	}

	test.expect_action_applied(
		t,
		&named,
		"Bind the switch variant",
		`package test

Ident :: struct {
	name: string,
}

Node :: union {
	^Ident,
	int,
}

named :: proc(n: Node) {
	switch x in n {
	case ^Ident:
		x.name = "y"
		x.name = "z"
	case int:
	}
}
`,
	)
}
