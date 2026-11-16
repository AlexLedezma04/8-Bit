; Exit with code 0.
section .text
global _start

_start:
    mov rax, 60        ; exit
    xor edi, edi
    syscall
msg: db "hi", 10
