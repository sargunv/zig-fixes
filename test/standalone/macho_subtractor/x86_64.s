    .data
    .globl _extsym
    .p2align 3
_extsym:
    .quad 0x1234

    .globl _weaksym
    .weak_definition _weaksym
    .p2align 3
_weaksym:
    .quad 0x5678

    .text
    .globl _get_extsym
_get_extsym:
    leaq Lextsym(%rip), %rcx
    movq (%rcx), %rax
    addq %rcx, %rax
    movq (%rax), %rax
    retq

    .globl _get_weaksym
_get_weaksym:
    leaq Lweaksym(%rip), %rcx
    movq (%rcx), %rax
    addq %rcx, %rax
    movq (%rax), %rax
    retq

    .p2align 3
Lextsym:
    .quad _extsym - .
Lweaksym:
    .quad _weaksym - .
