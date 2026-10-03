package p

Kind :: enum { A, B }
Item :: struct { kind: Kind }
take :: proc(it: Item) -> Kind { return it.kind }
main :: proc() {
	_ = take(Item{kind = .B})
}
