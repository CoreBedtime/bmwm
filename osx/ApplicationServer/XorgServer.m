#import "XorgServer.h"
#include <unistd.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <errno.h>

static const char *xorg_paths[] = {
    "/opt/local/bin/Xorg",
    "/opt/X11/bin/Xorg",
    NULL
};

@implementation XorgServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _xorgPid = -1;
        _displayNumber = -1;
    }
    return self;
}

- (const char *)findXorg {
    for (int i = 0; xorg_paths[i] != NULL; i++) {
        if (access(xorg_paths[i], X_OK) == 0) {
            return xorg_paths[i];
        }
    }
    return NULL;
}

- (int)writeXorgConfigWithWidth:(int)width height:(int)height {
    char config_template[] = "/tmp/applicator-xorg-XXXXXX";
    int config_fd = mkstemp(config_template);
    if (config_fd < 0) return -1;

    _configPath = [NSString stringWithUTF8String:config_template];
    char log_path[256];
    snprintf(log_path, sizeof(log_path), "/tmp/applicator-xorg-%ld.log", (long)getpid());
    _logPath = [[NSString stringWithUTF8String:log_path] retain];

    char mode_name[] = "Mode0";
    char modeline[] = "173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync";

    FILE *config = fdopen(config_fd, "w");
    if (!config) {
        close(config_fd);
        return -1;
    }

    fprintf(config,
        "Section \"ServerLayout\"\n"
        "    Identifier \"Layout0\"\n"
        "    Screen \"Screen0\"\n"
        "    InputDevice \"Mouse0\" \"CorePointer\"\n"
        "    InputDevice \"Keyboard0\" \"CoreKeyboard\"\n"
        "EndSection\n"
        "\n"
        "Section \"InputDevice\"\n"
        "    Identifier \"Mouse0\"\n"
        "    Driver \"void\"\n"
        "EndSection\n"
        "\n"
        "Section \"InputDevice\"\n"
        "    Identifier \"Keyboard0\"\n"
        "    Driver \"void\"\n"
        "EndSection\n"
        "\n"
        "Section \"Monitor\"\n"
        "    Identifier \"Monitor0\"\n"
        "    HorizSync 1.0-300.0\n"
        "    VertRefresh 1.0-300.0\n"
        "    Modeline \"%s\" %s\n"
        "EndSection\n"
        "\n"
        "Section \"Device\"\n"
        "    Identifier \"DummyDevice\"\n"
        "    Driver \"dummy\"\n"
        "    VideoRam 512000\n"
        "    Option \"Shadow\" \"no\"\n"
        "EndSection\n"
        "\n"
        "Section \"Screen\"\n"
        "    Identifier \"Screen0\"\n"
        "    Device \"DummyDevice\"\n"
        "    Monitor \"Monitor0\"\n"
        "    DefaultDepth 24\n"
        "    SubSection \"Display\"\n"
        "        Depth 24\n"
        "        Modes \"%s\"\n"
        "        Virtual %d %d\n"
        "        ViewPort 0 0\n"
        "    EndSubSection\n"
        "EndSection\n",
        mode_name, modeline, mode_name, width, height);

    fclose(config);
    return 0;
}

- (int)waitForDisplayFd:(int)fd displayNumber:(int *)displayNumber {
    char buffer[64] = {0};
    struct timeval timeout = { .tv_sec = 10, .tv_usec = 0 };
    fd_set read_fds;
    FD_ZERO(&read_fds);
    FD_SET(fd, &read_fds);

    if (select(fd + 1, &read_fds, NULL, NULL, &timeout) <= 0) return -1;
    if (read(fd, buffer, sizeof(buffer) - 1) <= 0) return -1;

    char *endptr = NULL;
    long display = strtol(buffer, &endptr, 10);
    if (endptr == buffer || display < 0 || display > 1024) return -1;

    *displayNumber = (int)display;
    return 0;
}

- (BOOL)spawnWithWidth:(int)width height:(int)height {
    const char *xorg = [self findXorg];
    if (!xorg) return NO;

    mkdir("/tmp/.X11-unix", 0777);
    chmod("/tmp/.X11-unix", 01777);

    if ([self writeXorgConfigWithWidth:width height:height] != 0) return NO;

    int display_pipe[2];
    if (pipe(display_pipe) != 0) return NO;

    pid_t pid = fork();
    if (pid < 0) {
        close(display_pipe[0]);
        close(display_pipe[1]);
        return NO;
    }

    if (pid == 0) {
        close(display_pipe[0]);
        dup2(display_pipe[1], 99);
        close(display_pipe[1]);

        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > STDERR_FILENO) close(devnull);
        }

        char *argv[] = { (char *)xorg, (char *)"-quiet", (char *)"-config", (char *)[_configPath UTF8String], (char *)"-noreset", (char *)"-logfile", (char *)[_logPath UTF8String], (char *)"-displayfd", (char *)"99", (char *)"-listen", (char *)"local", NULL };
        execv(xorg, argv);
        _exit(127);
    }

    close(display_pipe[1]);
    int display_num = -1;
    if ([self waitForDisplayFd:display_pipe[0] displayNumber:&display_num] != 0) {
        close(display_pipe[0]);
        return NO;
    }
    close(display_pipe[0]);

    _displayNumber = display_num;
    _xorgPid = pid;
    return YES;
}

- (void)stop {
    if (_xorgPid > 0) {
        kill(_xorgPid, SIGTERM);
        waitpid(_xorgPid, NULL, 0);
        _xorgPid = -1;
    }
    if (_configPath) {
        unlink([_configPath UTF8String]);
        [_configPath release];
        _configPath = nil;
    }
    if (_logPath) {
        unlink([_logPath UTF8String]);
        [_logPath release];
        _logPath = nil;
    }
}

- (void)dealloc {
    [self stop];
    [super dealloc];
}

@end
