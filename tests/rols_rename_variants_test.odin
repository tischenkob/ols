package tests

import "core:testing"

import test "src:testing"

// Renaming one branch of a `when` renames the declaration of the other branch, whichever branch holds the cursor.
@(test)
rename_variant_in_other_when_branch :: proc(t: ^testing.T) {
	expected := `package test

when ODIN_DEBUG {
	h :: proc(a: int) -> int { return a }
} else {
	h :: proc(a: int) -> int { return a + 1 }
	k :: proc() -> int { return h(2) }
}

g :: proc() -> int { return h(1) }
`
	for main in ([2]string{`package test

when ODIN_DEBUG {
	f{*} :: proc(a: int) -> int { return a }
} else {
	f :: proc(a: int) -> int { return a + 1 }
	k :: proc() -> int { return f(2) }
}

g :: proc() -> int { return f(1) }
`, `package test

when ODIN_DEBUG {
	f :: proc(a: int) -> int { return a }
} else {
	f{*} :: proc(a: int) -> int { return a + 1 }
	k :: proc() -> int { return f(2) }
}

g :: proc() -> int { return f(1) }
`}) {
		source := test.Source {
			main = main,
		}
		test.expect_rename(t, &source, "h", {{"main.odin", expected}})
	}
}

// A declaration in a file that the build tags keep from the host is a variant of the host's declaration, and the
// references inside that file are renamed with it, whichever file holds the cursor.
@(test)
rename_variant_in_excluded_file :: proc(t: ^testing.T) {
	host := `#+build !windows
package test

f :: proc() -> (v: int, ok: bool) {
	return 1, true
}
`
	excluded := `#+build windows
package test

f :: proc() -> (v: int, ok: bool) {
	return 2, true
}

twice :: proc() -> int {
	v, _ := f()
	return 2 * v
}
`
	use := `package test

g :: proc() -> int {
	v, ok := f()
	if !ok {
		return 0
	}
	return v
}
`
	expected := []test.File {
		{"f_host.odin", `#+build !windows
package test

h :: proc() -> (v: int, ok: bool) {
	return 1, true
}
`},
		{
			"f_windows.odin",
			`#+build windows
package test

h :: proc() -> (v: int, ok: bool) {
	return 2, true
}

twice :: proc() -> int {
	v, _ := h()
	return 2 * v
}
`,
		},
		{"use.odin", `package test

g :: proc() -> int {
	v, ok := h()
	if !ok {
		return 0
	}
	return v
}
`},
	}

	on_host := test.Source {
		files = {
			{
				"f_host.odin",
				"#+build !windows\npackage test\n\nf{*} :: proc() -> (v: int, ok: bool) {\n\treturn 1, true\n}\n",
			},
			{"f_windows.odin", excluded},
			{"use.odin", use},
		},
	}
	test.expect_rename(t, &on_host, "h", expected)

	on_excluded := test.Source {
		files = {
			{
				"f_windows.odin",
				"#+build windows\npackage test\n\nf{*} :: proc() -> (v: int, ok: bool) {\n\treturn 2, true\n}\n\ntwice :: proc() -> int {\n\tv, _ := f()\n\treturn 2 * v\n}\n",
			},
			{"f_host.odin", host},
			{"use.odin", use},
		},
	}
	test.expect_rename(t, &on_excluded, "h", expected)
}

// Two declarations that every build includes together are duplicates, not variants: only the one at the cursor
// is renamed. The same holds for two declarations in one `when` branch.
@(test)
rename_duplicate_is_not_a_variant :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

f{*} :: proc() {}

when ODIN_DEBUG {
	e :: proc() {}
	e :: proc() {}
}
`,
		files = {{"other.odin", `package test

f :: proc() {}
`}},
	}
	test.expect_rename(
		t,
		&source,
		"h",
		{
			{"main.odin", `package test

h :: proc() {}

when ODIN_DEBUG {
	e :: proc() {}
	e :: proc() {}
}
`},
			{"other.odin", `package test

f :: proc() {}
`},
		},
	)
}

// A variant that already declares the new name in its own file is a collision.
@(test)
rename_variant_collision_in_excluded_file :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `#+build !windows
package test

f{*} :: proc() {}
`,
		files = {{"f_windows.odin", `#+build windows
package test

f :: proc() {}
h :: proc() {}
`}},
	}
	test.expect_rename_refused(t, &source, "h", {"`h` is already declared in the package at test/f_windows.odin:5:1"})
}

// Reordering the parameters of one variant reorders every variant and the calls in every file.
@(test)
reorder_params_variants :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

when ODIN_DEBUG {
	f :: proc(a: int, b: string) -> int { return a }
} else {
	f{*} :: proc(a: int, b: string) -> int { return a + 1 }
}

g :: proc() -> int { return f(1, "x") }
`,
		files = {
			{
				"f_windows.odin",
				`#+build windows
package test

f :: proc(a: int, b: string) -> int { return a + 2 }

k :: proc() -> int { return f(2, "y") }
`,
			},
		},
	}
	test.expect_reorder_params(
		t,
		&source,
		{1, 0},
		{
			{
				"main.odin",
				`package test

when ODIN_DEBUG {
	f :: proc(b: string, a: int) -> int { return a }
} else {
	f :: proc(b: string, a: int) -> int { return a + 1 }
}

g :: proc() -> int { return f("x", 1) }
`,
			},
			{
				"f_windows.odin",
				`#+build windows
package test

f :: proc(b: string, a: int) -> int { return a + 2 }

k :: proc() -> int { return f("y", 2) }
`,
			},
		},
	)
}

// Variants whose parameters differ cannot be reordered consistently, so the reorder is refused.
@(test)
reorder_params_refuses_differing_variants :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

when ODIN_DEBUG {
	f :: proc(a: int, b: string) -> int { return a }
} else {
	f{*} :: proc(a: int, b: cstring) -> int { return a + 1 }
}
`,
	}
	test.expect_reorder_params(t, &source, {1, 0}, {})
}

// A file-private declaration is never a variant of one in another file, since each file may declare its own: the
// helper of the windows file keeps its name, by attribute or by `#+private file`.
@(test)
rename_file_private_is_not_a_variant :: proc(t: ^testing.T) {
	windows_files := [2]string {
		`#+build windows
package test

@(private = "file")
helper :: proc() -> int { return 2 }
`,
		`#+build windows
#+private file
package test

helper :: proc() -> int { return 2 }
`,
	}
	for windows in windows_files {
		source := test.Source {
			main  = `package test

@(private = "file")
hel{*}per :: proc() -> int { return 1 }

g :: proc() -> int { return helper() }
`,
			files = {{"b_windows.odin", windows}},
		}
		test.expect_rename(
			t,
			&source,
			"assist",
			{
				{
					"main.odin",
					`package test

@(private = "file")
assist :: proc() -> int { return 1 }

g :: proc() -> int { return assist() }
`,
				},
				{"b_windows.odin", windows},
			},
		)
	}
}
