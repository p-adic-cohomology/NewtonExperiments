#define _POSIX_C_SOURCE 200809L

#include "funsearch.h"
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct {
    int listener;
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int accepted;
} stub_server;

static int candidate_mode;
static int candidate_calls;

void curve(int32_t p, int32_t coeffs[21])
{
    ++candidate_calls;
    memset(coeffs, 0, 21 * sizeof(*coeffs));
    if (candidate_mode == 1)
        return;
    coeffs[0] = 1;
    coeffs[1] = 2;
    if (candidate_mode == 2)
        coeffs[3] = p;
}

static void *resolve_candidate(const char *name)
{
    return strcmp(name, "curve") == 0 ? (void *)curve : NULL;
}

static void *resolve_missing(const char *name)
{
    (void)name;
    return NULL;
}

static int read_request(int fd, char *request, size_t capacity)
{
    size_t used = 0;
    while (used + 1 < capacity) {
        char byte;
        ssize_t count = recv(fd, &byte, 1, 0);
        if (count <= 0)
            return -1;
        if (byte == '\n') {
            request[used] = '\0';
            return 0;
        }
        request[used++] = byte;
    }
    return -1;
}

static int send_response(int fd)
{
    static const char response[] =
        "{\"status\":\"OK\",\"score\":12.5,\"sig\":[1,2],\"msg\":\"stub ok\"}\n";
    size_t sent = 0;
    while (sent < sizeof(response) - 1) {
        ssize_t count = send(fd, response + sent, sizeof(response) - 1 - sent, 0);
        if (count <= 0)
            return -1;
        sent += (size_t)count;
    }
    return 0;
}

static void *serve_two_connections(void *opaque)
{
    stub_server *server = opaque;
    for (int i = 0; i < 2; ++i) {
        int client = accept(server->listener, NULL, NULL);
        if (client < 0)
            return NULL;
        ++server->accepted;
        char request[8192];
        if (read_request(client, request, sizeof(request)) != 0 ||
            strstr(request, "\"instance\":\"family=plane,d=5,p=7") == NULL ||
            strstr(request, "\"coeffs\":[1,2") == NULL ||
            send_response(client) != 0) {
            close(client);
            return NULL;
        }
        close(client);
    }
    close(server->listener);
    server->listener = -1;
    unlink(server->path);
    return NULL;
}

static int start_stub(stub_server *server, pthread_t *thread)
{
    memset(server, 0, sizeof(*server));
    server->listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server->listener < 0)
        return -1;
    snprintf(server->path, sizeof(server->path), "/tmp/fsn-%ld.sock", (long)getpid());
    unlink(server->path);
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, server->path, strlen(server->path) + 1);
#ifdef __APPLE__
    address.sun_len = (unsigned char)(offsetof(struct sockaddr_un, sun_path) + strlen(server->path) + 1);
#endif
    if (bind(server->listener, (struct sockaddr *)&address,
             (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(server->path) + 1)) != 0 ||
        listen(server->listener, 4) != 0)
        return -1;
    return pthread_create(thread, NULL, serve_two_connections, server);
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    snprintf(path, sizeof(path), "/tmp/fsn-down-%ld.sock", (long)getpid());
    unlink(path);
    assert(setenv("FUNSEARCH_NEWTON_SOCKET", path, 1) == 0);
    assert(fs_init("family=plane,d=5,p=7") != 0);

    stub_server server;
    pthread_t server_thread;
    assert(start_stub(&server, &server_thread) == 0);
    assert(setenv("FUNSEARCH_NEWTON_SOCKET", server.path, 1) == 0);
    assert(fs_init("family=plane,d=5,p=7") == 0);

    fs_result result = fs_score(resolve_missing, "family=plane,d=5,p=7");
    assert(result.status == FS_ERROR);
    assert(strstr(result.msg, "curve") != NULL);

    candidate_mode = 1;
    result = fs_score(resolve_candidate, "family=plane,d=5,p=7");
    assert(result.status == FS_INVALID);
    assert(strstr(result.msg, "zero") != NULL);

    candidate_mode = 2;
    result = fs_score(resolve_candidate, "family=plane,d=5,p=7");
    assert(result.status == FS_INVALID);
    assert(strstr(result.msg, "0:p-1") != NULL);

    candidate_mode = 0;
    result = fs_score(resolve_candidate, "family=plane,d=5,p=7,reward=mixed");
    assert(result.status == FS_OK);
    assert(result.score == 12.5);
    assert(result.nsig == 2 && result.sig[0] == 1.0 && result.sig[1] == 2.0);
    assert(strcmp(result.msg, "stub ok") == 0);

    result = fs_score(resolve_candidate, "family=plane,d=5,p=7,reward=mixed");
    assert(result.status == FS_OK);
    assert(result.score == 12.5);
    assert(pthread_join(server_thread, NULL) == 0);
    assert(server.accepted == 2);

    result = fs_score(resolve_candidate, "family=plane,d=5,p=7,reward=mixed");
    assert(result.status == FS_ERROR);
    assert(result.score == 0.0);
    assert(candidate_calls == 5);
    fs_fini();
    puts("shim unit tests passed: stub response, local validation, server down, reconnect");
    return 0;
}
