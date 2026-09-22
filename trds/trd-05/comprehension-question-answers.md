Why must pthread_cond_wait() be inside a while loop, not an if?
    ANS: Condvar can cause spurious wakeups (false positives), so we check other conditions along with wrapping in a while to certify conditions are met (tasks present, not shutting down)
What happens if threadpool_destroy() calls pthread_cond_signal() instead of pthread_cond_broadcast()?
    ANS: Only one thread would receive this signal and stop operating, the other N-1 threads would become zombie threads that are forever waiting in the while loop
Why remove the connection's fd from epoll before handing it to a worker thread?
    ANS: Worker thread now owns that FD, Epoll's only job is to receive the request (updated from 04) so that file IO and writing is done by the worker. We don't care to update on writes, writes are performed on the thread.
If two workers dequeue simultaneously, what prevents them from getting the same task?
    ANS: Mutex prevents this; only one thread can have mutex at a time which revents simultaneous dequeueing, they can call dequeue at the same time but only one will run at a time. 