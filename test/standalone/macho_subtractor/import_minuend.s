    .text
    .globl _main
    .p2align 2
_main:
    mov w0, #0
    ret
    .p2align 3
    .quad _malloc - .
