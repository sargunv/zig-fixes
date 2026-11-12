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
    .p2align 2
_get_extsym:
    adr x1, Lextsym
    ldr x0, [x1]
    add x0, x0, x1
    ldr x0, [x0]
    ret

    .globl _get_weaksym
    .p2align 2
_get_weaksym:
    adr x1, Lweaksym
    ldr x0, [x1]
    add x0, x0, x1
    ldr x0, [x0]
    ret

    .p2align 3
Lextsym:
    .quad _extsym - .
Lweaksym:
    .quad _weaksym - .
