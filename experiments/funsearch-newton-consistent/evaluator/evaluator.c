#define _POSIX_C_SOURCE 200809L

#include "funsearch.h"
#include "../candidate.h"
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>

#define MAX_INSTANCE_BYTES 4096
#define REQUEST_BYTES 8192
#define RESPONSE_BYTES 16384

typedef void (*curve_fn)(int32_t, int32_t[21]);

static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static int server_fd = -1;
static char server_socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static char response_buffer[RESPONSE_BYTES];
static size_t response_buffer_used;

static void set_message(fs_result *result, const char *message)
{
    if (message == NULL)
        message = "";
    snprintf(result->msg, sizeof(result->msg), "%s", message);
}

static fs_result make_result(fs_status status, const char *message)
{
    fs_result result;
    memset(&result, 0, sizeof(result));
    result.status = status;
    set_message(&result, message);
    return result;
}

static void close_server_locked(void)
{
    if (server_fd >= 0)
        close(server_fd);
    server_fd = -1;
    response_buffer_used = 0;
}

static int load_socket_path(const char *path, char *message, size_t message_size)
{
    if (path == NULL || path[0] == '\0') {
        if (message_size > 0)
            snprintf(message, message_size, "%s", "FUNSEARCH_NEWTON_SOCKET is not set");
        return -1;
    }
    size_t length = strlen(path);
    if (length >= sizeof(server_socket_path)) {
        if (message_size > 0)
            snprintf(message, message_size, "%s", "FUNSEARCH_NEWTON_SOCKET is too long");
        return -1;
    }
    memcpy(server_socket_path, path, length + 1);
    return 0;
}

static int connect_server_locked(char *message, size_t message_size)
{
    if (server_socket_path[0] == '\0' &&
        load_socket_path(getenv("FUNSEARCH_NEWTON_SOCKET"), message, message_size) != 0)
        return -1;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        snprintf(message, message_size, "socket: %s", strerror(errno));
        return -1;
    }
#ifdef SO_NOSIGPIPE
    int no_sigpipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
#endif

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    size_t path_length = strlen(server_socket_path);
    memcpy(address.sun_path, server_socket_path, path_length + 1);
    socklen_t address_length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + path_length + 1);
#ifdef __APPLE__
    address.sun_len = (unsigned char)address_length;
#endif
    if (connect(fd, (struct sockaddr *)&address, address_length) != 0) {
        snprintf(message, message_size, "connect %s: %s", server_socket_path, strerror(errno));
        close(fd);
        return -1;
    }
    server_fd = fd;
    return 0;
}

static int parse_prime(const char *instance, int32_t *prime)
{
    if (instance == NULL)
        return -1;
    size_t length = strnlen(instance, MAX_INSTANCE_BYTES + 1);
    if (length == 0 || length > MAX_INSTANCE_BYTES)
        return -1;

    int found = 0;
    const char *cursor = instance;
    const char *end = instance + length;
    while (cursor < end) {
        const char *token_end = memchr(cursor, ',', (size_t)(end - cursor));
        if (token_end == NULL)
            token_end = end;
        const char *equals = memchr(cursor, '=', (size_t)(token_end - cursor));
        if (equals != NULL) {
            const char *key_start = cursor;
            const char *key_end = equals;
            while (key_start < key_end && isspace((unsigned char)*key_start))
                ++key_start;
            while (key_end > key_start && isspace((unsigned char)key_end[-1]))
                --key_end;
            if (key_end - key_start == 1 && key_start[0] == 'p') {
                if (found)
                    return -1;
                found = 1;
                const char *value_start = equals + 1;
                while (value_start < token_end && isspace((unsigned char)*value_start))
                    ++value_start;
                const char *value_end = token_end;
                while (value_end > value_start && isspace((unsigned char)value_end[-1]))
                    --value_end;
                size_t value_length = (size_t)(value_end - value_start);
                if (value_length == 0 || value_length >= 32)
                    return -1;
                char value[32];
                memcpy(value, value_start, value_length);
                value[value_length] = '\0';
                errno = 0;
                char *parse_end = NULL;
                long parsed = strtol(value, &parse_end, 10);
                if (errno != 0 || parse_end == value || *parse_end != '\0' ||
                    parsed < 2 || parsed > INT32_MAX)
                    return -1;
                *prime = (int32_t)parsed;
            }
        }
        cursor = token_end + (token_end < end);
    }
    return found ? 0 : -1;
}

static int append_bytes(char *output, size_t capacity, size_t *used, const char *bytes, size_t count)
{
    if (count > capacity - *used)
        return -1;
    memcpy(output + *used, bytes, count);
    *used += count;
    return 0;
}

static int append_json_string(char *output, size_t capacity, size_t *used, const char *value)
{
    if (append_bytes(output, capacity, used, "\"", 1) != 0)
        return -1;
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor != '\0'; ++cursor) {
        char escaped[7];
        size_t count = 1;
        escaped[0] = (char)*cursor;
        if (*cursor == '"' || *cursor == '\\') {
            escaped[0] = '\\';
            escaped[1] = (char)*cursor;
            count = 2;
        } else if (*cursor == '\b' || *cursor == '\f' || *cursor == '\n' ||
                   *cursor == '\r' || *cursor == '\t') {
            escaped[0] = '\\';
            escaped[1] = *cursor == '\b' ? 'b' : *cursor == '\f' ? 'f' :
                         *cursor == '\n' ? 'n' : *cursor == '\r' ? 'r' : 't';
            count = 2;
        } else if (*cursor < 0x20) {
            snprintf(escaped, sizeof(escaped), "\\u%04x", *cursor);
            count = 6;
        }
        if (append_bytes(output, capacity, used, escaped, count) != 0)
            return -1;
    }
    return append_bytes(output, capacity, used, "\"", 1);
}

static int build_request(const char *instance, const int32_t coefficients[21],
                         char *output, size_t capacity, size_t *length)
{
    size_t used = 0;
    if (append_bytes(output, capacity, &used, "{\"instance\":", 12) != 0 ||
        append_json_string(output, capacity, &used, instance) != 0 ||
        append_bytes(output, capacity, &used, ",\"coeffs\":[", 11) != 0)
        return -1;
    for (int i = 0; i < 21; ++i) {
        char number[32];
        int written = snprintf(number, sizeof(number), "%s%d", i == 0 ? "" : ",", coefficients[i]);
        if (written < 0 || (size_t)written >= sizeof(number) ||
            append_bytes(output, capacity, &used, number, (size_t)written) != 0)
            return -1;
    }
    if (append_bytes(output, capacity, &used, "]}\n", 3) != 0)
        return -1;
    *length = used;
    return 0;
}

static int send_all(int fd, const char *bytes, size_t length)
{
    size_t sent = 0;
    while (sent < length) {
#ifdef MSG_NOSIGNAL
        ssize_t count = send(fd, bytes + sent, length - sent, MSG_NOSIGNAL);
#else
        ssize_t count = send(fd, bytes + sent, length - sent, 0);
#endif
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return -1;
        sent += (size_t)count;
    }
    return 0;
}

static int read_response_line(int fd, char *output, size_t capacity)
{
    if (capacity == 0)
        return -1;

    for (;;) {
        char *newline = memchr(response_buffer, '\n', response_buffer_used);
        if (newline != NULL) {
            size_t line_length = (size_t)(newline - response_buffer);
            if (line_length >= capacity)
                return -1;
            memcpy(output, response_buffer, line_length);
            output[line_length] = '\0';
            size_t remaining = response_buffer_used - line_length - 1;
            memmove(response_buffer, newline + 1, remaining);
            response_buffer_used = remaining;
            return 0;
        }

        if (response_buffer_used == sizeof(response_buffer))
            return -1;
        ssize_t count = recv(fd, response_buffer + response_buffer_used,
                             sizeof(response_buffer) - response_buffer_used, 0);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return -1;
        response_buffer_used += (size_t)count;
    }
}

static const char *skip_space(const char *cursor)
{
    while (*cursor != '\0' && isspace((unsigned char)*cursor))
        ++cursor;
    return cursor;
}

static const char *skip_string(const char *cursor)
{
    if (*cursor != '"')
        return NULL;
    ++cursor;
    while (*cursor != '\0') {
        if (*cursor == '"')
            return cursor + 1;
        if (*cursor == '\\') {
            ++cursor;
            if (*cursor == '\0')
                return NULL;
            if (*cursor == 'u') {
                for (int i = 0; i < 4; ++i) {
                    ++cursor;
                    if (!isxdigit((unsigned char)*cursor))
                        return NULL;
                }
            }
        }
        ++cursor;
    }
    return NULL;
}

static const char *skip_value(const char *cursor, int depth)
{
    cursor = skip_space(cursor);
    if (depth > 32 || *cursor == '\0')
        return NULL;
    if (*cursor == '"')
        return skip_string(cursor);
    if (*cursor == '{') {
        ++cursor;
        cursor = skip_space(cursor);
        if (*cursor == '}')
            return cursor + 1;
        for (;;) {
            const char *key_end = skip_string(cursor);
            if (key_end == NULL)
                return NULL;
            cursor = skip_space(key_end);
            if (*cursor++ != ':')
                return NULL;
            cursor = skip_value(cursor, depth + 1);
            if (cursor == NULL)
                return NULL;
            cursor = skip_space(cursor);
            if (*cursor == '}')
                return cursor + 1;
            if (*cursor++ != ',')
                return NULL;
            cursor = skip_space(cursor);
        }
    }
    if (*cursor == '[') {
        ++cursor;
        cursor = skip_space(cursor);
        if (*cursor == ']')
            return cursor + 1;
        for (;;) {
            cursor = skip_value(cursor, depth + 1);
            if (cursor == NULL)
                return NULL;
            cursor = skip_space(cursor);
            if (*cursor == ']')
                return cursor + 1;
            if (*cursor++ != ',')
                return NULL;
            cursor = skip_space(cursor);
        }
    }
    while (*cursor != '\0' && *cursor != ',' && *cursor != ']' &&
           *cursor != '}' && !isspace((unsigned char)*cursor))
        ++cursor;
    return cursor;
}

static int decode_string(const char *cursor, char *output, size_t capacity,
                         const char **after)
{
    if (*cursor != '"')
        return -1;
    ++cursor;
    size_t used = 0;
    while (*cursor != '\0' && *cursor != '"') {
        unsigned char value = (unsigned char)*cursor++;
        if (value == '\\') {
            char escape = *cursor++;
            if (escape == '\0')
                return -1;
            if (escape == '"' || escape == '\\' || escape == '/')
                value = (unsigned char)escape;
            else if (escape == 'b')
                value = '\b';
            else if (escape == 'f')
                value = '\f';
            else if (escape == 'n')
                value = '\n';
            else if (escape == 'r')
                value = '\r';
            else if (escape == 't')
                value = '\t';
            else if (escape == 'u') {
                unsigned int codepoint = 0;
                for (int i = 0; i < 4; ++i) {
                    unsigned char digit = (unsigned char)*cursor++;
                    if (!isxdigit(digit))
                        return -1;
                    codepoint = (codepoint << 4) |
                        (unsigned int)(isdigit(digit) ? digit - '0' :
                        (tolower(digit) - 'a' + 10));
                }
                value = codepoint < 0x80 ? (unsigned char)codepoint : (unsigned char)'?';
            } else {
                return -1;
            }
        }
        if (used + 1 < capacity)
            output[used++] = (char)value;
    }
    if (*cursor != '"')
        return -1;
    ++cursor;
    if (capacity > 0)
        output[used] = '\0';
    if (after != NULL)
        *after = cursor;
    return 0;
}

static const char *find_key(const char *json, const char *wanted)
{
    const char *cursor = skip_space(json);
    if (*cursor++ != '{')
        return NULL;
    cursor = skip_space(cursor);
    while (*cursor != '\0' && *cursor != '}') {
        char key[128];
        const char *after_key = NULL;
        if (decode_string(cursor, key, sizeof(key), &after_key) != 0)
            return NULL;
        cursor = skip_space(after_key);
        if (*cursor++ != ':')
            return NULL;
        const char *value = skip_space(cursor);
        if (strcmp(key, wanted) == 0)
            return value;
        cursor = skip_value(value, 0);
        if (cursor == NULL)
            return NULL;
        cursor = skip_space(cursor);
        if (*cursor == '}')
            break;
        if (*cursor++ != ',')
            return NULL;
        cursor = skip_space(cursor);
    }
    return NULL;
}

static int parse_number(const char *cursor, double *number, const char **after)
{
    cursor = skip_space(cursor);
    errno = 0;
    char *end = NULL;
    double value = strtod(cursor, &end);
    if (end == cursor || errno == ERANGE || !isfinite(value))
        return -1;
    const char *tail = skip_space(end);
    if (*tail != ',' && *tail != ']' && *tail != '}' && *tail != '\0')
        return -1;
    *number = value;
    if (after != NULL)
        *after = tail;
    return 0;
}

static int parse_signature(const char *cursor, fs_result *result)
{
    cursor = skip_space(cursor);
    if (*cursor++ != '[')
        return -1;
    cursor = skip_space(cursor);
    if (*cursor == ']') {
        result->nsig = 0;
        return 0;
    }
    int32_t count = 0;
    for (;;) {
        if (count == 8)
            return -1;
        double value;
        const char *after = NULL;
        if (parse_number(cursor, &value, &after) != 0)
            return -1;
        result->sig[count++] = value;
        cursor = skip_space(after);
        if (*cursor == ']') {
            result->nsig = count;
            return 0;
        }
        if (*cursor++ != ',')
            return -1;
        cursor = skip_space(cursor);
    }
}

static int parse_server_response(const char *json, fs_result *result)
{
    const char *status_value = find_key(json, "status");
    const char *score_value = find_key(json, "score");
    const char *signature_value = find_key(json, "sig");
    const char *message_value = find_key(json, "msg");
    if (status_value == NULL || score_value == NULL ||
        signature_value == NULL || message_value == NULL)
        return -1;

    char status[32];
    if (decode_string(status_value, status, sizeof(status), NULL) != 0)
        return -1;
    double score;
    if (parse_number(score_value, &score, NULL) != 0)
        return -1;
    fs_result parsed;
    memset(&parsed, 0, sizeof(parsed));
    if (parse_signature(signature_value, &parsed) != 0)
        return -1;
    if (decode_string(message_value, parsed.msg, sizeof(parsed.msg), NULL) != 0)
        return -1;
    parsed.score = score;
    if (strcmp(status, "OK") == 0)
        parsed.status = FS_OK;
    else if (strcmp(status, "INVALID") == 0)
        parsed.status = FS_INVALID;
    else if (strcmp(status, "ERROR") == 0)
        parsed.status = FS_ERROR;
    else
        return -1;
    *result = parsed;
    return 0;
}

static int exchange_locked(const char *request, size_t request_length,
                           char *response, size_t response_capacity)
{
    if (server_fd < 0)
        return -1;
    if (send_all(server_fd, request, request_length) != 0)
        return -1;
    return read_response_line(server_fd, response, response_capacity);
}

int fs_init(const char *instance)
{
    (void)instance;
    struct timespec started = {0, 0};
    struct timespec finished = {0, 0};
    clock_gettime(CLOCK_MONOTONIC, &started);
    char message[256] = {0};
    pthread_mutex_lock(&state_lock);
    close_server_locked();
    if (load_socket_path(getenv("FUNSEARCH_NEWTON_SOCKET"), message, sizeof(message)) != 0 ||
        connect_server_locked(message, sizeof(message)) != 0) {
        pthread_mutex_unlock(&state_lock);
        clock_gettime(CLOCK_MONOTONIC, &finished);
        double elapsed = (finished.tv_sec - started.tv_sec) +
                         (finished.tv_nsec - started.tv_nsec) / 1.0e9;
        fprintf(stderr, "[newton-evaluator] fs_init failed after %.6f s: %s\n", elapsed, message);
        return -1;
    }
    pthread_mutex_unlock(&state_lock);
    clock_gettime(CLOCK_MONOTONIC, &finished);
    double elapsed = (finished.tv_sec - started.tv_sec) +
                     (finished.tv_nsec - started.tv_nsec) / 1.0e9;
    fprintf(stderr, "[newton-evaluator] fs_init_seconds=%.6f\n", elapsed);
    return 0;
}

void fs_fini(void)
{
    pthread_mutex_lock(&state_lock);
    close_server_locked();
    pthread_mutex_unlock(&state_lock);
}

fs_result fs_score(fs_resolve_fn resolve, const char *instance)
{
    fs_result result = make_result(FS_ERROR, "evaluator failed");
    int32_t prime = 0;
    if (parse_prime(instance, &prime) != 0)
        return make_result(FS_INVALID, "instance must contain one prime p");
    if (resolve == NULL)
        return make_result(FS_ERROR, "candidate resolver is missing");

    void *symbol = resolve("curve");
    if (symbol == NULL)
        return make_result(FS_ERROR, "candidate does not export curve");
    curve_fn candidate = (curve_fn)symbol;
    int32_t coefficients[21] = {0};
    candidate(prime, coefficients);
    int nonzero = 0;
    for (int i = 0; i < 21; ++i) {
        if (coefficients[i] < 0 || coefficients[i] >= prime)
            return make_result(FS_INVALID, "coefficients must lie in 0:p-1");
        nonzero |= coefficients[i] != 0;
    }
    if (!nonzero)
        return make_result(FS_INVALID, "the zero polynomial is invalid");

    char request[REQUEST_BYTES];
    size_t request_length = 0;
    if (build_request(instance, coefficients, request, sizeof(request), &request_length) != 0)
        return make_result(FS_INVALID, "instance is too large to send");
    char response[RESPONSE_BYTES];
    char message[256] = {0};

    pthread_mutex_lock(&state_lock);
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (server_fd < 0 && connect_server_locked(message, sizeof(message)) != 0)
            break;
        if (exchange_locked(request, request_length, response, sizeof(response)) == 0) {
            if (parse_server_response(response, &result) != 0)
                result = make_result(FS_ERROR, "score server returned an invalid response");
            pthread_mutex_unlock(&state_lock);
            return result;
        }
        snprintf(message, sizeof(message), "%s", "score server connection broke during request");
        close_server_locked();
        if (attempt == 0)
            continue;
    }
    pthread_mutex_unlock(&state_lock);
    return make_result(FS_ERROR, message[0] == '\0' ? "score server is unavailable" : message);
}
