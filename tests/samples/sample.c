#include <stdio.h>

/* Entry point. */
int main(int argc, char **argv) {
    const char *name = argc > 1 ? argv[1] : "world";
    printf("hello, %s\n", name); // greet
    return 0;
}
