#ifndef FILEHUB_FILE_SERVICE_H
#define FILEHUB_FILE_SERVICE_H

#include "http_request.h"
#include "http_response.h"

/*
 * 根据请求构造静态文件响应。路径的每一级都相对 root_fd 打开，并使用
 * O_NOFOLLOW 禁止符号链接跳出站点根目录。成功打开的文件描述符转移给
 * filehub_http_response_t，调用方负责用 filehub_http_response_close() 释放。
 */
void filehub_file_prepare_response(int root_fd,
                                   const filehub_http_request_t *request,
                                   filehub_http_response_t *response);

#endif
