#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

__attribute__((constructor)) static void shockemu_canary_loaded(void) {
    const char *path = getenv("SHOCKEMU_CANARY_PATH");
    if (path == NULL || path[0] == '\0') {
        return;
    }

    int descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (descriptor < 0) {
        return;
    }

    static const char message[] = "ShockEmu canary loaded\n";
    (void)write(descriptor, message, strlen(message));
    (void)close(descriptor);
}
