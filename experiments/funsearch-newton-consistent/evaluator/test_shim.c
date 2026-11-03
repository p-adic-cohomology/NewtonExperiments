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

#define MAX_REQUEST 65536
#define STUB_REQUESTS 4

enum {
    CANDIDATE_PARTIAL = 1,
    CANDIDATE_ALL_INVALID = 2,
    CANDIDATE_LARGE = 3,
    CANDIDATE_NORMAL = 4
};

typedef struct {
    int listener;
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int accepted;
    int failed;
    size_t request_lengths[STUB_REQUESTS];
    int sample_counts[STUB_REQUESTS];
} stub_server;

static int candidate_mode;
static int candidate_calls;
static int32_t candidate_k[256];

void curve(int32_t p, int32_t k, int32_t coeffs[21])
{
    candidate_k[candidate_calls++] = k;
    memset(coeffs, 0, 21 * sizeof(*coeffs));
    if (candidate_mode == CANDIDATE_PARTIAL) {
        if (k == 0) {
            coeffs[0] = 1;
            coeffs[1] = 2;
        } else if (k == 2) {
            coeffs[0] = p;
        }
        return;
    }
    if (candidate_mode == CANDIDATE_ALL_INVALID)
        return;
    if (candidate_mode == CANDIDATE_LARGE) {
        for (int i = 0; i < 21; ++i)
            coeffs[i] = p - 1;
        return;
    }
    coeffs[0] = 1;
    coeffs[1] = k % p;
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

static int read_request(int fd, char *request, size_t capacity, size_t *length)
{
    size_t used = 0;
    while (used + 1 < capacity) {
        char byte;
        ssize_t count = recv(fd, &byte, 1, 0);
        if (count <= 0)
            return -1;
        if (byte == '\n') {
            request[used] = '\0';
            *length = used;
            return 0;
        }
        request[used++] = byte;
    }
    return -1;
}

static int count_samples(const char *request)
{
    const char *cursor = strstr(request, "\"samples\":[");
    if (cursor == NULL)
        return 0;
    int count = 1;
    while ((cursor = strstr(cursor, "],[")) != NULL) {
        ++count;
        cursor += 3;
    }
    return count;
}

static int send_response(int fd, int request_index)
{
    static const char ok_response[] =
        "{\"status\":\"OK\",\"score\":12.5,\"sig\":[1,2,3,4,5],\"msg\":\"stub ok\"}\n";
    static const char invalid_response[] =
        "{\"status\":\"INVALID\",\"score\":0,\"sig\":[0,0,0,0,0],\"msg\":\"S=0 distinct=0/3 i i i\"}\n";
    const char *response = request_index == 1 ? invalid_response : ok_response;
    size_t length = strlen(response);
    return send(fd, response, length, 0) == (ssize_t)length ? 0 : -1;
}

static void *serve_requests(void *opaque)
{
    stub_server *server = opaque;
    static const int expected_samples[STUB_REQUESTS] = {3, 3, 64, 16};
    for (int i = 0; i < STUB_REQUESTS; ++i) {
        int client = accept(server->listener, NULL, NULL);
        if (client < 0) {
            server->failed = 1;
            break;
        }
        ++server->accepted;
        char request[MAX_REQUEST];
        size_t length = 0;
        if (read_request(client, request, sizeof(request), &length) != 0) {
            server->failed = 1;
            close(client);
            break;
        }
        server->request_lengths[i] = length;
        server->sample_counts[i] = count_samples(request);
        if (server->sample_counts[i] != expected_samples[i])
            server->failed = 1;
        if (i == 0) {
            if (strstr(request, "\"instance\":\"family=plane,d=5,p=7,k=3\"") == NULL ||
                strstr(request, "\"samples\":[[1,2,0") == NULL ||
                strstr(request, "],[0,0,0") == NULL ||
                strstr(request, "],[7,0,0") == NULL)
                server->failed = 1;
        } else if (i == 1) {
            if (strstr(request, "\"samples\":[[0,0,0") == NULL)
                server->failed = 1;
        } else if (i == 2) {
            if (length <= 8192 ||
                strstr(request, "\"instance\":\"family=plane,d=5,p=2147483647,k=64\"") == NULL ||
                strstr(request, "\"samples\":[[2147483646,2147483646") == NULL)
                server->failed = 1;
        } else if (strstr(request, "\"instance\":\"family=plane,d=5,p=7\"") == NULL ||
                   strstr(request, ",k=") != NULL) {
            server->failed = 1;
        }
        if (send_response(client, i) != 0)
            server->failed = 1;
        close(client);
        if (server->failed)
            break;
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
    return pthread_create(thread, NULL, serve_requests, server);
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
    assert(fs_init("family=plane,d=5,p=7,k=3") == 0);

    fs_result result = fs_score(resolve_missing, "family=plane,d=5,p=7,k=3");
    assert(result.status == FS_ERROR);
    assert(strstr(result.msg, "curve") != NULL);
    assert(candidate_calls == 0);

    result = fs_score(resolve_candidate, "family=plane,d=5,p=7,k=0");
    assert(result.status == FS_INVALID);
    result = fs_score(resolve_candidate, "family=plane,d=5,p=7,k=3,k=4");
    assert(result.status == FS_INVALID);
    assert(candidate_calls == 0);

    candidate_mode = CANDIDATE_PARTIAL;
    result = fs_score(resolve_candidate, "family=plane,d=5,p=7,k=3");
    assert(result.status == FS_OK);
    assert(result.score == 12.5);
    assert(result.nsig == 5 && result.sig[4] == 5.0);
    assert(strcmp(result.msg, "stub ok") == 0);
    assert(candidate_calls == 3);
    assert(candidate_k[0] == 0 && candidate_k[1] == 1 && candidate_k[2] == 2);

    candidate_mode = CANDIDATE_ALL_INVALID;
    result = fs_score(resolve_candidate, "family=plane,d=5,p=7,k=3");
    assert(result.status == FS_INVALID);
    assert(result.score == 0.0);
    assert(result.nsig == 5);
    assert(candidate_calls == 6);
    assert(candidate_k[3] == 0 && candidate_k[4] == 1 && candidate_k[5] == 2);

    candidate_mode = CANDIDATE_LARGE;
    result = fs_score(resolve_candidate, "family=plane,d=5,p=2147483647,k=64");
    assert(result.status == FS_OK);
    assert(candidate_calls == 70);
    for (int k = 0; k < 64; ++k)
        assert(candidate_k[6 + k] == k);

    candidate_mode = CANDIDATE_NORMAL;
    result = fs_score(resolve_candidate, "family=plane,d=5,p=7");
    assert(result.status == FS_OK);
    assert(candidate_calls == 86);
    for (int k = 0; k < 16; ++k)
        assert(candidate_k[70 + k] == k);

    assert(pthread_join(server_thread, NULL) == 0);
    assert(server.failed == 0);
    assert(server.accepted == STUB_REQUESTS);
    assert(server.sample_counts[0] == 3);
    assert(server.sample_counts[1] == 3);
    assert(server.sample_counts[2] == 64);
    assert(server.sample_counts[3] == 16);
    assert(server.request_lengths[2] > 8192);

    result = fs_score(resolve_candidate, "family=plane,d=5,p=7");
    assert(result.status == FS_ERROR);
    assert(result.score == 0.0);
    assert(candidate_calls == 102);
    for (int k = 0; k < 16; ++k)
        assert(candidate_k[86 + k] == k);
    fs_fini();
    puts("shim unit tests passed: K-sample calls, batch encoding, invalid samples, large requests, reconnect");
    return 0;
}
