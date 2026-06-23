// mcmonad-tcc-spawn — a transparent spawn wrapper that disclaims TCC
// "responsibility" for its child.
//
// Why this exists: macOS attributes privacy prompts (Microphone, Speech
// Recognition, …) and stores the resulting grant against the *responsible
// process*, not necessarily the process that calls the API. A binary
// spawned as a child of the bash launcher (which is MCMonad.app's main
// executable) inherits the launcher / app bundle as its responsible
// process, so mcmonad-core's microphone request is attributed to
// com.mcmonad.app instead of com.mcmonad.core — the prompt misfires and the
// grant never sticks to the binary that actually carries the
// NSMicrophoneUsageDescription. This is the same reason a CLI that needs the
// mic "just works" when run from a terminal: the terminal is its own
// responsible app and the child inherits it.
//
// responsibility_spawnattrs_setdisclaim(attr, 1) tells the kernel the child
// is responsible for *itself*. It is a private libSystem SPI, but a stable
// one — it is exactly what launchd and /usr/bin/open use to launch apps as
// their own responsible process. With it, mcmonad-core becomes its own TCC
// client: the mic/speech prompt is attributed to com.mcmonad.core (whose
// embedded Info.plist supplies the usage strings) and the grant persists.
//
// The wrapper is transparent: it forwards SIGTERM/SIGINT to the child and
// exits with the child's status, so the launcher's "did the core die?"
// monitoring (which watches the backgrounded pid) keeps working — the
// wrapper lives exactly as long as mcmonad-core.

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// Private but stable libSystem SPI (declared in the SDK's spawn_private.h on
// some toolchains; declare it ourselves so we don't depend on that header).
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attr,
                                                 int disclaim);

static volatile pid_t g_child = 0;

static void forward_signal(int sig) {
    if (g_child > 0) {
        kill(g_child, sig);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s PROGRAM [args...]\n", argv[0]);
        return 2;
    }

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        perror("posix_spawnattr_init");
        return 1;
    }
    // Make the child its own TCC-responsible process.
    responsibility_spawnattrs_setdisclaim(&attr, 1);

    signal(SIGTERM, forward_signal);
    signal(SIGINT, forward_signal);

    pid_t child = 0;
    int rc = posix_spawn(&child, argv[1], NULL, &attr, &argv[1], environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        fprintf(stderr, "mcmonad-tcc-spawn: posix_spawn(%s) failed: %s\n",
                argv[1], strerror(rc));
        return 1;
    }
    g_child = child;

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            perror("waitpid");
            return 1;
        }
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return 0;
}
