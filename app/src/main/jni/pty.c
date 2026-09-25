/*
 * Minimal POSIX PTY session for the terminal app.
 * Creates a master/slave pair, forks dash, and exposes blocking I/O to JNI.
 */
#include <jni.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>

#define MAX_ENV 64

typedef struct {
    int master;
    pid_t pid;
    int alive;
} PtySession;

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static void set_nonblock(int fd, int enabled) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return;
    if (enabled) flags |= O_NONBLOCK;
    else flags &= ~O_NONBLOCK;
    fcntl(fd, F_SETFL, flags);
}

static void write_all(int fd, const char *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, data + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return;
        }
        off += (size_t) n;
    }
}

static void child_setup(int slave, const char *cwd, char **envp) {
    setsid();
    if (ioctl(slave, TIOCSCTTY, 0) < 0) {
        /* Older kernels may not accept the request; controlling tty is still
         * established by opening the slave after setsid on many devices. */
    }
    dup2(slave, STDIN_FILENO);
    dup2(slave, STDOUT_FILENO);
    dup2(slave, STDERR_FILENO);
    if (slave > STDERR_FILENO) close(slave);
    if (cwd != NULL && cwd[0] != '\0') {
        if (chdir(cwd) != 0) {
            /* Fall through; the shell can still start in the inherited cwd. */
        }
    }
    if (envp != NULL) {
        for (int i = 0; envp[i] != NULL; i++) {
            char *eq = strchr(envp[i], '=');
            if (eq == NULL || eq == envp[i]) continue;
            *eq = '\0';
            setenv(envp[i], eq + 1, 1);
            *eq = '=';
        }
    }
}

static char **copy_env(JNIEnv *env, jobjectArray array, char *storage[], int *count) {
    if (array == NULL) {
        *count = 0;
        return NULL;
    }
    jsize n = (*env)->GetArrayLength(env, array);
    if (n > MAX_ENV - 1) n = MAX_ENV - 1;
    for (jsize i = 0; i < n; i++) {
        jstring item = (jstring) (*env)->GetObjectArrayElement(env, array, i);
        const char *utf = (*env)->GetStringUTFChars(env, item, NULL);
        storage[i] = strdup(utf);
        (*env)->ReleaseStringUTFChars(env, item, utf);
        (*env)->DeleteLocalRef(env, item);
    }
    storage[n] = NULL;
    *count = (int) n;
    return storage;
}

static void free_env(char *storage[], int count) {
    for (int i = 0; i < count; i++) free(storage[i]);
}

JNIEXPORT jlong JNICALL
Java_com_terminal_Pty_nativeOpen(JNIEnv *env, jclass clazz,
                                 jstring jShell, jstring jCwd, jobjectArray jEnv,
                                 jint rows, jint cols) {
    (void) clazz;
    const char *shell = (*env)->GetStringUTFChars(env, jShell, NULL);
    const char *cwd = jCwd != NULL ? (*env)->GetStringUTFChars(env, jCwd, NULL) : NULL;
    char *envStorage[MAX_ENV];
    int envCount = 0;
    char **envp = copy_env(env, jEnv, envStorage, &envCount);

    int master = -1;
    char slaveName[128];
    memset(slaveName, 0, sizeof(slaveName));
    master = open("/dev/ptmx", O_RDWR | O_CLOEXEC);
    if (master < 0) goto fail;
    if (grantpt(master) != 0 || unlockpt(master) != 0) goto fail;
    if (ptsname_r(master, slaveName, sizeof(slaveName)) != 0) goto fail;

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short) (rows > 0 ? rows : 40);
    ws.ws_col = (unsigned short) (cols > 0 ? cols : 100);
    ioctl(master, TIOCSWINSZ, &ws);

    pid_t pid = fork();
    if (pid < 0) goto fail;
    if (pid == 0) {
        int slave = open(slaveName, O_RDWR);
        if (slave < 0) _exit(127);
        close(master);
        child_setup(slave, cwd, envp);
        char *argv[] = {(char *) shell, (char *) "-i", NULL};
        execve(shell, argv, envp != NULL ? envp : environ);
        write_all(STDERR_FILENO, "terminal: failed to exec shell\n", 30);
        _exit(127);
    }

    PtySession *session = calloc(1, sizeof(PtySession));
    if (session == NULL) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        goto fail;
    }
    session->master = master;
    session->pid = pid;
    session->alive = 1;
    set_nonblock(master, 1);

    free_env(envStorage, envCount);
    (*env)->ReleaseStringUTFChars(env, jShell, shell);
    if (cwd != NULL) (*env)->ReleaseStringUTFChars(env, jCwd, cwd);
    return (jlong) session;

fail:
    if (master >= 0) close(master);
    free_env(envStorage, envCount);
    if (shell != NULL) (*env)->ReleaseStringUTFChars(env, jShell, shell);
    if (cwd != NULL) (*env)->ReleaseStringUTFChars(env, jCwd, cwd);
    return 0;
}

JNIEXPORT jint JNICALL
Java_com_terminal_Pty_nativeRead(JNIEnv *env, jclass clazz, jlong handle, jbyteArray buffer) {
    (void) clazz;
    PtySession *session = (PtySession *) handle;
    if (session == NULL || session->master < 0) return -1;
    jsize cap = (*env)->GetArrayLength(env, buffer);
    jbyte *bytes = (*env)->GetByteArrayElements(env, buffer, NULL);
    ssize_t n = read(session->master, bytes, (size_t) cap);
    int err = errno;
    (*env)->ReleaseByteArrayElements(env, buffer, bytes, 0);
    if (n < 0) {
        if (err == EAGAIN || err == EWOULDBLOCK) return 0;
        return -1;
    }
    return (jint) n;
}

JNIEXPORT jint JNICALL
Java_com_terminal_Pty_nativeWrite(JNIEnv *env, jclass clazz, jlong handle, jbyteArray data, jint length) {
    (void) clazz;
    PtySession *session = (PtySession *) handle;
    if (session == NULL || session->master < 0 || length < 0) return -1;
    jbyte *bytes = (*env)->GetByteArrayElements(env, data, NULL);
    ssize_t n = write(session->master, bytes, (size_t) length);
    int err = errno;
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    if (n < 0) {
        if (err == EAGAIN || err == EWOULDBLOCK) return 0;
        return -1;
    }
    return (jint) n;
}

JNIEXPORT void JNICALL
Java_com_terminal_Pty_nativeResize(JNIEnv *env, jclass clazz, jlong handle, jint rows, jint cols) {
    (void) env;
    (void) clazz;
    PtySession *session = (PtySession *) handle;
    if (session == NULL || session->master < 0) return;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short) (rows > 0 ? rows : 1);
    ws.ws_col = (unsigned short) (cols > 0 ? cols : 1);
    ioctl(session->master, TIOCSWINSZ, &ws);
}

JNIEXPORT jint JNICALL
Java_com_terminal_Pty_nativeWait(JNIEnv *env, jclass clazz, jlong handle, jint block) {
    (void) env;
    (void) clazz;
    PtySession *session = (PtySession *) handle;
    if (session == NULL || session->pid <= 0) return -1;
    int status = 0;
    pid_t result = waitpid(session->pid, &status, block ? 0 : WNOHANG);
    if (result == 0) return -2;
    if (result < 0) return -1;
    session->alive = 0;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return status;
}

JNIEXPORT void JNICALL
Java_com_terminal_Pty_nativeClose(JNIEnv *env, jclass clazz, jlong handle) {
    (void) env;
    (void) clazz;
    PtySession *session = (PtySession *) handle;
    if (session == NULL) return;
    if (session->master >= 0) {
        close(session->master);
        session->master = -1;
    }
    if (session->pid > 0 && session->alive) {
        kill(session->pid, SIGHUP);
        int status = 0;
        for (int i = 0; i < 20; i++) {
            pid_t result = waitpid(session->pid, &status, WNOHANG);
            if (result != 0) break;
            usleep(10000);
        }
        if (waitpid(session->pid, &status, WNOHANG) == 0) {
            kill(session->pid, SIGKILL);
            waitpid(session->pid, &status, 0);
        }
    }
    free(session);
}
