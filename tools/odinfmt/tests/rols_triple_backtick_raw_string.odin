// Corpus: core/rexcode/isa/riscv/tablegen/gen.odin:364. The tokenizer reads ``` as three adjacent strings, so no `;` joins them.
package odinfmt_test

TEXT :: ```
line one
line two
```

x :: 1

g :: proc() { T :: ```abc``` }
