#ifndef FILEHUB_HTTP_RESPONSE_H
#define FILEHUB_HTTP_RESPONSE_H

#include <stddef.h>
#include <sys/types.h>

/*
 * 响应描述对象。响应体要么来自 body，要么来自 file_fd；当 file_fd >= 0
 * 时，该描述符由此对象持有，必须最终通过 filehub_http_response_close() 释放。
 */
typedef struct {
    int status;                  /* HTTP 状态码。 */
    const char *reason;          /* 状态原因短语，指向静态字符串。 */
    const char *content_type;    /* MIME 类型，指向静态字符串。 */
    char body[1024];             /* 错误页或内置端点的小型响应体。 */
    size_t body_len;
    int file_fd;                 /* 待发送文件；-1 表示使用内存响应体。 */
    off_t file_start;
    off_t file_end;              /* 半开区间终点，不包含该位置。 */
    off_t full_size;             /* Range 响应引用的原文件总长度。 */
    int partial;                 /* 是否生成 206 Content-Range。 */
    int head_only;
    int keep_alive;
} filehub_http_response_t;

/* 初始化为空响应，并把 file_fd 设为安全的无效值 -1。 */
void filehub_http_response_init(filehub_http_response_t *response);
/* 构造不带文件的标准错误响应。 */
void filehub_http_response_set_error(filehub_http_response_t *response, int status,
                                     int keep_alive, int head_only);
/* 释放响应持有的文件描述符；可重复调用。 */
void filehub_http_response_close(filehub_http_response_t *response);
/* 序列化响应头；成功返回字节数，缓冲区不足或格式化失败返回 -1。 */
int filehub_http_response_format_headers(const filehub_http_response_t *response,
                                         char *buffer, size_t capacity);

#endif
