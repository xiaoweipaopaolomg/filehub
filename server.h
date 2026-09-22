#ifndef FILEHUB_SERVER_H
#define FILEHUB_SERVER_H

#include "config.h"

/*
 * 启动并运行 FileHub Reactor。函数接管运行期资源，在正常 SIGINT/SIGTERM
 * 停机后返回 0；初始化或事件循环失败时清理资源并返回 -1。
 */
int filehub_server_run(const filehub_config_t *config);

#endif
