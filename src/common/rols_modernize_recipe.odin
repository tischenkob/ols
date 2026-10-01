package common

import "core:strings"

// One `modernize_recipes` entry of ols.json: `ols query modernize` rewrites code that matches
// `match` into `replace`. `$name` in either is a metavariable.
Modernize_Recipe :: struct {
	name:    string,
	match:   string,
	replace: string,
	imports: []string, // import paths the replacement needs, like "core:slice"
	// The trailing underscore makes the server's unmarshal read the `where` key; the tag does it
	// for core:encoding/json.
	where_:  []Modernize_Recipe_Where `json:"where"`,
}

// The metavariable var, without `$`, must bind a value of this kind: slice, dynamic_array,
// fixed_array, map, string or pointer.
Modernize_Recipe_Where :: struct {
	var:  string,
	kind: string,
}

clone_modernize_recipes :: proc(recipes: []Modernize_Recipe, allocator := context.allocator) -> []Modernize_Recipe {
	out := make([]Modernize_Recipe, len(recipes), allocator)
	for recipe, i in recipes {
		out[i] = {
			name    = strings.clone(recipe.name, allocator),
			match   = strings.clone(recipe.match, allocator),
			replace = strings.clone(recipe.replace, allocator),
			imports = clone_string_list(recipe.imports, allocator),
			where_  = make([]Modernize_Recipe_Where, len(recipe.where_), allocator),
		}
		for w, j in recipe.where_ {
			out[i].where_[j] = {strings.clone(w.var, allocator), strings.clone(w.kind, allocator)}
		}
	}
	return out
}
