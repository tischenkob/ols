package p

B :: distinct b32
g :: proc() -> B { return true }
f :: proc() -> bool { return g() == true }
