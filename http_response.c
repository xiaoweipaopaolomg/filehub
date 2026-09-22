#include "http_response.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

void filehub_http_response_init(filehub_http_response_t *response) {
    memset(response, 0, sizeof(*response));
    response->file_fd = -1;
    response->content_type = "text/plain; charset=utf-8";
}

/* 所有错误响应从同一处生成，确保状态行、正文和连接语义一致。 */
void filehub_http_response_set_error(filehub_http_response_t *response, int status,
                                     int keep_alive, int head_only) {
    filehub_http_response_init(response);
    response->status = status;
    response->keep_alive = keep_alive;
    response->head_only = head_only;
    switch (status) {
        case 400: response->reason = "Bad Request"; break;
        case 403: response->reason = "Forbidden"; break;
        case 404: response->reason = "Not Found"; break;
        case 405: response->reason = "Method Not Allowed"; break;
        case 408: response->reason = "Request Timeout"; break;
        case 416: response->reason = "Range Not Satisfiable"; break;
        case 431: response->reason = "Request Header Fields Too Large"; break;
        case 503: response->reason = "Service Unavailable"; break;
        default: response->status = 500; response->reason = "Internal Server Error"; break;
    }
    int formatted_length = snprintf(response->body, sizeof(response->body),
                                    "%d %s\n", response->status, response->reason);
    response->body_len = formatted_length > 0 ? (size_t)formatted_length : 0;
}

void filehub_http_response_close(filehub_http_response_t *response) {
    if (response->file_fd >= 0) close(response->file_fd);
    response->file_fd = -1;
}

int filehub_http_response_format_headers(const filehub_http_response_t *response,
                                         char *buffer, size_t capacity) {
    /* Range 使用 [file_start, file_end)，因此长度直接用二者之差计算。 */
    uintmax_t length = response->file_fd >= 0 ? (uintmax_t)(response->file_end - response->file_start) : (uintmax_t)response->body_len;
    int formatted_length = snprintf(buffer, capacity,
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %ju\r\n"
        "Connection: %s\r\n",
        response->status, response->reason, response->content_type, length,
        response->keep_alive ? "keep-alive" : "close");
    if (formatted_length < 0 || (size_t)formatted_length >= capacity) return -1;
    size_t used = (size_t)formatted_length;
    if (response->file_fd >= 0 || response->status == 416) {
        /* 正常文件响应和 416 都声明服务端理解字节范围请求。 */
        formatted_length = snprintf(buffer + used, capacity - used, "Accept-Ranges: bytes\r\n");
        if (formatted_length < 0 || (size_t)formatted_length >= capacity - used) return -1;
        used += (size_t)formatted_length;
    }
    if (response->partial) {
        /* 协议中的结束位置是闭区间，所以序列化时使用 file_end - 1。 */
        formatted_length = snprintf(buffer + used, capacity - used,
            "Content-Range: bytes %ju-%ju/%ju\r\n",
            (uintmax_t)response->file_start, (uintmax_t)(response->file_end - 1),
            (uintmax_t)response->full_size);
        if (formatted_length < 0 || (size_t)formatted_length >= capacity - used) return -1;
        used += (size_t)formatted_length;
    } else if (response->status == 416) {
        formatted_length = snprintf(buffer + used, capacity - used,
                                    "Content-Range: bytes */%ju\r\n",
                                    (uintmax_t)response->full_size);
        if (formatted_length < 0 || (size_t)formatted_length >= capacity - used) return -1;
        used += (size_t)formatted_length;
    }
    if (capacity - used < 3) return -1;
    memcpy(buffer + used, "\r\n", 2);
    buffer[used + 2] = '\0';
    return (int)(used + 2);
}
