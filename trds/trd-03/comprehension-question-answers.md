What happens if response_cleanup() calls free() on a string literal? How does the ownership flag prevent this?
    ANS: It creates a segfault; string literals are in read only memory within the program
    binaries (.rodata for example). The ownership flag allows the destructor (response_free) 
    to know whether the response body was created outside of the context of the response_t
    (other things might point at it) or if the response body was malloc'd (and therefore
    needs to be free'd)
Why should Content-Length be set automatically inside the engine rather than by the caller?
    ANS: Content length is part of the internal state of the response(?), having the caller
    calculate the size of the body can be inaccurate since the body might change and therefore
    there would be multiple content-length headers that are stale
If write() returns fewer bytes than the full response, what happened? (Think about what TRD-04 will need to handle.)
    ANS: Can happen because of insufficient memory on the disk (if writing to file) OR 
    an interrupt/block on the socket that is being written to. Maybe the client had a timeout?
When would the server legitimately return 500 instead of 400 or 404?
    ANS: If it had an internal error when trying to legally read a file, copy to a buffer (insufficient
    memory)