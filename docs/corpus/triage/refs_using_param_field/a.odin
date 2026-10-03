#+feature using-stmt
package p

W :: struct { id: u32 }
f :: proc(using w: ^W) -> u32 { return id }
