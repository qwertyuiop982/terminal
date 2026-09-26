/*
 * Minimal POSIX PTY session for the terminal app.
 * Creates a master/slave pair, forks dash, and exposes non-blocking I/O
 * to JNI. A single global mutex guards every session access so close()
 * racing with in-flight read()/write() calls can never touch freed memory:
 * the session leaves the registry before it is freed, and stale handles
 * simply fail the lookup.
 */
#include <jni.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>

#define MAX_SESSIONS 16
#define MAX_ENV 64

typedef struct {
    int master;
    pid_t pid;
} PtySession;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static PtySession *g_sessions[MAX_SESSIONS];

static PtySession *find_session_locked(jlong handle) {
    PtySession *session = (PtySession *) handle;
    int i;
    if (session == NULL) return NULL;
    for (i = 0; i < MAX_SESSIONS; i++) {
        if (g_sessions[i] == session) return session;
    }
    return NULL;
}

static int register_session(PtySession *session) {
    int i;
    pthread_mutex_lock(&g_lock);
    for (i = 0; i < MAX_SESSIONS; i++) {
        if (g_sessions[i] == NULL) {
            g_sessions[i] = session;
            pthread_mutex_unlock(&g_lock);
            return 0;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return -1;
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

static void child_setup(int slave, const char *cwd) {
    setsid();
    ioctl(slave, TIOCSCTTY, 0);
    dup2(slave, STDIN_FILENO);
    dup2(slave, STDOUT_FILENO);
    dup2(slave, STDERR_FILENO);
    if (slave > STDERR_FILENO) close(slave);
    if (cwd != NULL && cwd[0] != '\0') {
        chdir(cwd); /* keep the inherited cwd when chdir fails */
    }
}

static char **copy_env(JNIEnv *env, jobjectArray array, char *storage[], int *count) {
    jsize n;
    jsize i;
    if (array == NULL) {
        *count = 0;
        return NULL;
    }
    n = (*env)->GetArrayLength(env, array);
    if (n > MAX_ENV - 1) n = MAX_ENV - 1;
    for (i = 0; i < n; i++) {
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
    int i;
    for (i = 0; i < count; i++) free(storage[i]);
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
    struct winsize ws;
    pid_t pid;
    PtySession *session;

    memset(slaveName, 0, sizeof(slaveName));
    master = open("/dev/ptmx", O_RDWR | O_CLOEXEC);
    if (master < 0) goto fail;
    if (grantpt(master) != 0 || unlockpt(master) != 0) goto fail;
    if (ptsname_r(master, slaveName, sizeof(slaveName)) != 0) goto fail;

    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short) (rows > 0 ? rows : 40);
    ws.ws_col = (unsigned short) (cols > 0 ? cols : 100);
    ioctl(master, TIOCSWINSZ, &ws);

    pid = fork();
    if (pid < 0) goto fail;
    if (pid == 0) {
        int slave = open(slaveName, O_RDWR);
        if (slave < 0) _exit(127);
        close(master);
        child_setup(slave, cwd);
        {
            char *argv[] = {(char *) shell, (char *) "-i", NULL};
            execve(shell, argv, envp != NULL ? envp : environ);
        }
        write_all(STDERR_FILENO, "terminal: failed to exec shell\n",
                  sizeof("terminal: failed to exec shell\n") - 1);
        _exit(127);
    }

    session = calloc(1, sizeof(PtySession));
    if (session == NULL) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        goto fail;
    }
    session->master = master;
    session->pid = pid;
    if (register_session(session) != 0) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        free(session);
        goto fail;
    }
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
    PtySession *session;
    jbyte *bytes;
    jsize cap;
    ssize_t n;
    int err;

    pthread_mutex_lock(&g_lock);
    session = find_session_locked(handle);
    if (session == NULL || session->master < 0) {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    cap = (*env)->GetArrayLength(env, buffer);
    if (cap <= 0) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    bytes = (*env)->GetByteArrayElements(env, buffer, NULL);
    if (bytes == NULL) {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    do {
        n = read(session->master, bytes, (size_t) cap);
    } while (n < 0 && errno == EINTR);
    err = errno;
    (*env)->ReleaseByteArrayElements(env, buffer, bytes, n > 0 ? 0 : JNI_ABORT);
    pthread_mutex_unlock(&g_lock);
    if (n < 0) {
        /* EIO: slave 端已关闭，即子进程退出。返回 0 让 Java 读循环
         * 走到 poll() 收割状态码。 */
        if (err == EAGAIN || err == EWOULDBLOCK || err == EIO) return 0;
        return -1;
    }
    return (jint) n;
}

JNIEXPORT jint JNICALL
Java_com_terminal_Pty_nativeWrite(JNIEnv *env, jclass clazz, jlong handle, jbyteArray data, jint length) {
    (void) clazz;
    PtySession *session;
    jbyte *bytes;
    ssize_t n;
    int err;

    pthread_mutex_lock(&g_lock);
    session = find_session_locked(handle);
    if (session == NULL || session->master < 0 || length < 0) {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    bytes = (*env)->GetByteArrayElements(env, data, NULL);
    if (bytes == NULL) {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    do {
        n = write(session->master, bytes, (size_t) length);
    } while (n < 0 && errno == EINTR);
    err = errno;
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    pthread_mutex_unlock(&g_lock);
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
    PtySession *session;
    struct winsize ws;

    pthread_mutex_lock(&g_lock);
    session = find_session_locked(handle);
    if (session == NULL || session->master < 0) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short) (rows > 0 ? rows : 1);
    ws.ws_col = (unsigned short) (cols > 0 ? cols : 1);
    ioctl(session->master, TIOCSWINSZ, &ws);
    pthread_mutex_unlock(&g_lock);
}

JNIEXPORT jint JNICALL
Java_com_terminal_Pty_nativeWait(JNIEnv *env, jclass clazz, jlong handle, jint block) {
    (void) env;
    (void) clazz;
    PtySession *session;
    int status = 0;
    pid_t result;

    pthread_mutex_lock(&g_lock);
    session = find_session_locked(handle);
    if (session == NULL || session->pid <= 0) {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    result = waitpid(session->pid, &status, block ? 0 : WNOHANG);
    pthread_mutex_unlock(&g_lock);
    if (result == 0) return -2;
    if (result < 0) return -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return status;
}

JNIEXPORT void JNICALL
Java_com_terminal_Pty_nativeClose(JNIEnv *env, jclass clazz, jlong handle) {
    (void) env;
    (void) clazz;
    PtySession *session;
    int master;
    pid_t pid;
    int status = 0;
    int i;

    pthread_mutex_lock(&g_lock);
    session = find_session_locked(handle);
    if (session == NULL) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    /* 先从注册表摘除：此后任何在途调用拿着旧 handle 只会查找失败，
     * 不会与下面的 free() 产生 use-after-free。 */
    for (i = 0; i < MAX_SESSIONS; i++) {
        if (g_sessions[i] == session) {
            g_sessions[i] = NULL;
            break;
        }
    }
    master = session->master;
    session->master = -1;
    pid = session->pid;
    pthread_mutex_unlock(&g_lock);

    if (master >= 0) close(master);
    if (pid > 0) {
        kill(pid, SIGHUP);
        for (i = 0; i < 20; i++) {
            if (waitpid(pid, &status, WNOHANG) != 0) break;
            usleep(10000);
        }
        if (waitpid(pid, &status, WNOHANG) == 0) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
        }
    }
    free(session);
}