What does socket(AF_INET, SOCK_STREAM, 0) actually return, and what does the kernel do when it's called?

ANS: It returns a file descriptor for an endpoint in network communication. The kernel goes through multiple steps when a C program calls socket(). In brief,socket()
sets off various other syscalls that validate input, initialize structs in memory, call protocol-specific constructors and ultimately creates a VFS wrapper to allow
write() and read() operations.

Why is SO_REUSEADDR needed, and what happens without it when restarting the server quickly?

ANS: It's needed to allow a process to bind to a given address/port even if there was a recently closed connection.
The kernel prevents connections from being made to an addr/port if a connection recently closed on it, but SO_REUSEADDR
bypasses this check. 

What is the listen() backlog, and what happens when it fills up?
ANS: It's a queue of pending client connections for a given socket. If it fills up, pending connections may be lost/dropped

What's the difference between the listening FD and the client FD returned by accept()?
ANS: The listening fd is where client connections can be bound to, and client FDs are connections to a specific client which is
created using accept()

Why does Content-Length matter, and what breaks if it's wrong?
ANS: It tells the client how many bytes of data to expect within the response body. If it's too low then response body
content might be lost, if it's too high then the client may hang waiting for data.

What does Connection: close tell the client?
ANS: Tells the client the connection is closed after this response.

What happens if close() is never called on the client FD in the loop?
ANS: The process 'leaks' FDs and if it leaks too many then it will cause an error. 