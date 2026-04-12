#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdio.h>

__attribute__((visibility("default")))
int AppLaunchRun(void);

__attribute__((constructor))
static void initializer(void)
{
}
