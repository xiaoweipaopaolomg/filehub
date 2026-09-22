What happens if you call read() only once per EPOLLIN event in edge-triggered mode?
    ANS: Part of the request may be unread, since the client FD is nonblocking
    it might not receive the entire read in a single iteration which can lead to the client hanging. The data is there but the signal won't be sent to read it, only when it goes from empty to nonempty and vice versa.

Why must the listen socket's accept handler also loop until EAGAIN?
    ANS: Because in ET mode it'll only be marked as available for IO on the first client request/connection, there may be more pending that are not picked up
Explain the difference between storing fd vs. a connection_t * pointer in epoll_event.data. Why is the pointer approach better?
    ANS: The pointer approach allows us to store information about the connection like the FD, request, response, serialized buffer etc.; we can manage state with a connection * 
What is the purpose of write_offset and what bug does it prevent?
    ANS: Since writes may be partial we might not get an entire successful write. The write_offset variable points us at where we left off on our last write (or at the start). Prevents overwriting previously received data, allows us to manage state in serializing, also lets us prevent overflow.
Why can't the event loop call sleep(), scanf(), or any other blocking function?
    ANS: They block the entire loop and can cause delays as a result. Scanf tries to read from stdin which holds up the loop, sleep() also holds up the loop by waiting