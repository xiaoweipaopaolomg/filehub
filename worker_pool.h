#ifndef FILEHUB_WORKER_POOL_H
#define FILEHUB_WORKER_POOL_H

#include "http_request.h"
#include "http_response.h"
#include <pthread.h>
#include <stdint.h>

/*
 * 单个文件准备任务。token 绑定连接槽位与代次，防止任务完成时把旧结果
 * 投递给已经复用同一槽位的新连接。
 */
typedef struct filehub_work_item {
    struct filehub_work_item *next;
    uint64_t token;              /* 高 32 位为代次，低 32 位为连接槽位。 */
    filehub_http_request_t request;
    filehub_http_response_t response;
} filehub_work_item_t;

/*
 * 有界线程池。pending 队列保存待处理任务，done 队列保存已完成响应；
 * 两条链表及 queue_length、shutdown 均由 mutex 保护。
 */
typedef struct {
    pthread_t *threads;          /* 已创建工作线程的数组。 */
    int thread_count;
    int document_root_fd;        /* 只读共享的站点根目录描述符。 */
    int completion_event_fd;     /* 完成队列通知事件循环的 eventfd。 */
    int shutting_down;           /* 置位后不再接受任务，并唤醒线程退出。 */
    int pending_limit;
    int pending_count;
    pthread_mutex_t mutex;
    pthread_cond_t task_available;/* pending 队列由空变为非空时唤醒工作线程。 */
    filehub_work_item_t *pending_head;
    filehub_work_item_t *pending_tail;
    filehub_work_item_t *done_head;
    filehub_work_item_t *done_tail;
} filehub_worker_pool_t;

/* 初始化工作线程和 eventfd；失败时函数会回收已经创建的资源。 */
int filehub_worker_pool_init(filehub_worker_pool_t *pool, int thread_count,
                             int pending_limit, int document_root_fd);
/* 成功入队返回 0；队列已满、正在关闭或分配失败时返回 -1。 */
int filehub_worker_pool_submit(filehub_worker_pool_t *pool, uint64_t connection_token,
                               const filehub_http_request_t *request);
/* 从完成队列取出一个任务；队列为空时返回 NULL，任务所有权交给调用方。 */
filehub_work_item_t *filehub_worker_pool_take_result(filehub_worker_pool_t *pool);
/* 停止并等待所有线程，然后释放队列、同步原语和 eventfd。 */
void filehub_worker_pool_destroy(filehub_worker_pool_t *pool);

#endif
