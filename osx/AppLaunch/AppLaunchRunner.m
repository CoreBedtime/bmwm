#include <stdio.h>

__attribute__((constructor))
static void initializer(void) {
    printf("hello world\n");
}
