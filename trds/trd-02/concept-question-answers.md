Why is checking for .. in the raw URI insufficient to prevent directory traversal?
    ANS: It can be URL encoded with %2e OR other malicious encodings can be made like /././ or 
    otherwise to bypass the check
What does realpath() return if the target file does not exist?
    ANS: returns NULL and sets errno to ENOENT 
Why use fstat() on an open fd rather than stat() on the path? (Think about race conditions.)
    ANS: We use fstat instead of stat because we can verify (b/c the FD exists) that the file is present
    and we have quicker access to that file. With stat(), the file has to be navigated to, and this
    may result in the file changing by the time we get the size.
What happens if read() returns fewer bytes than st_size? Is the file corrupt, or is something else going on?
    ANS: Read() returns fewer bytes if it reached EOF (ret. 0) OR there was an interrupt/not enough bytes
    to even read. The file is not corrupt.
Why does .jpg map to image/jpeg and not image/jpg?
    ANS:  JPG is the old extension used by Windows machines when extensions were limited to
    3 characters. JPEG is the 'modern' extension; both represent the same format just with different
    extensions. MIME types use the file format not the extension.