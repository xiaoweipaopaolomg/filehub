#define _GNU_SOURCE
#include "worker_pool.h"
#include "file_service.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

/*
 * 工作线程只执行可能阻塞的文件打开与元数据准备，不接触客户端 socket
 * 和 epoll。这样客户端连接生命周期始终由 Reactor 单线程管理。
 */
static void *filehub_worker_thread_main(void *argument) {
    filehub_worker_pool_t *pool = argument;
    for (;;) {
        pthread_mutex_lock(&pool->mutex);
        while (!pool->pending_head && !pool->shutting_down)
            pthread_cond_wait(&pool->task_available, &pool->mutex);
        /* 关闭时仍会处理完已经进入 pending 队列的任务。 */
        if (!pool->pending_head && pool->shutting_down) {
            pthread_mutex_unlock(&pool->mutex);
            return NULL;
        }
        filehub_work_item_t *item = pool->pending_head;
        pool->pending_head = item->next;
        if (!pool->pending_head) pool->pending_tail = NULL;
        --pool->pending_count;
        pthread_mutex_unlock(&pool->mutex);

        filehub_file_prepare_response(pool->document_root_fd, &item->request,
                                      &item->response);
        item->next = NULL;
        pthread_mutex_lock(&pool->mutex);
        if (pool->done_tail) pool->done_tail->next = item;
        else pool->done_head = item;
        pool->done_tail = item;
        pthread_mutex_unlock(&pool->mutex);
        /* eventfd 只承担“有结果可取”的通知，结果本身仍存放在 done 队列。 */
        uint64_t one = 1;
        ssize_t unused = write(pool->completion_event_fd, &one, sizeof(one));
        (void)unused;
    }
}

int filehub_worker_pool_init(filehub_worker_pool_t *pool, int thread_count,
                             int pending_limit, int document_root_fd) {
    memset(pool, 0, sizeof(*pool));
    pool->completion_event_fd = -1;
    pool->document_root_fd = document_root_fd;
    pool->pending_limit = pending_limit;
    if (pthread_mutex_init(&pool->mutex, NULL)) return -1;
    if (pthread_cond_init(&pool->task_available, NULL)) {
        pthread_mutex_destroy(&pool->mutex);
        return -1;
    }
    pool->completion_event_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    pool->threads = calloc((size_t)thread_count, sizeof(*pool->threads));
    if (pool->completion_event_fd < 0 || !pool->threads) {
        filehub_worker_pool_destroy(pool);
        return -1;
    }
    for (int thread_index = 0; thread_index < thread_count; ++thread_index) {
        if (pthread_create(&pool->threads[thread_index], NULL,
                           filehub_worker_thread_main, pool)) {
            filehub_worker_pool_destroy(pool);
            return -1;
        }
        ++pool->thread_count;
    }
    return 0;
}

int filehub_worker_pool_submit(filehub_worker_pool_t *pool, uint64_t connection_token,
                               const filehub_http_request_t *request) {
    filehub_work_item_t *item = calloc(1, sizeof(*item));
    if (!item) return -1;
    item->token = connection_token;
    item->request = *request;
    pthread_mutex_lock(&pool->mutex);
    /* 有界队列在过载时快速失败，由上层向客户端返回 503。 */
    if (pool->shutting_down || pool->pending_count >= pool->pending_limit) {
        pthread_mutex_unlock(&pool->mutex);
        free(item);
        return -1;
    }
    if (pool->pending_tail) pool->pending_tail->next = item;
    else pool->pending_head = item;
    pool->pending_tail = item;
    ++pool->pending_count;
    pthread_cond_signal(&pool->task_available);
    pthread_mutex_unlock(&pool->mutex);
    return 0;
}

filehub_work_item_t *filehub_worker_pool_take_result(filehub_worker_pool_t *pool) {
    pthread_mutex_lock(&pool->mutex);
    filehub_work_item_t *item = pool->done_head;
    if (item) {
        pool->done_head = item->next;
        if (!pool->done_head) pool->done_tail = NULL;
        item->next = NULL;
    }
    pthread_mutex_unlock(&pool->mutex);
    return item;
}

void filehub_worker_pool_destroy(filehub_worker_pool_t *pool) {
    /* 先广播退出条件，再 join；此后才能安全销毁互斥量和条件变量。 */
    pthread_mutex_lock(&pool->mutex);
    pool->shutting_down = 1;
    pthread_cond_broadcast(&pool->task_available);
    pthread_mutex_unlock(&pool->mutex);
    for (int thread_index = 0; thread_index < pool->thread_count; ++thread_index)
        pthread_join(pool->threads[thread_index], NULL);
    free(pool->threads);
    /* pending 尚未生成响应；done 中的响应可能持有文件描述符。 */
    filehub_work_item_t *item = pool->pending_head;
    while (item) {
        filehub_work_item_t *next = item->next;
        free(item);
        item = next;
    }
    item = pool->done_head;
    while (item) {
        filehub_work_item_t *next = item->next;
        filehub_http_response_close(&item->response);
        free(item);
        item = next;
    }
    if (pool->completion_event_fd >= 0) close(pool->completion_event_fd);
    pthread_cond_destroy(&pool->task_available);
    pthread_mutex_destroy(&pool->mutex);
}
