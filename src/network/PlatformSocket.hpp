#pragma once

#ifdef _WIN32
    #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
    #endif
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #include <windows.h>

    using socket_t = SOCKET;
#else
    #include <sys/types.h>
    #include <sys/socket.h>
    #include <sys/select.h>
    #include <sys/time.h>
    #include <netinet/in.h>
    #include <netinet/tcp.h>
    #include <arpa/inet.h>
    #include <netdb.h>
    #include <unistd.h>
    #include <fcntl.h>
    #include <errno.h>

    using socket_t = int;

    #ifndef INVALID_SOCKET
    #define INVALID_SOCKET (-1)
    #endif

    #ifndef SOCKET_ERROR
    #define SOCKET_ERROR (-1)
    #endif

    #ifndef closesocket
    #define closesocket(s) close(s)
    #endif

    #ifndef WSAGetLastError
    #define WSAGetLastError() errno
    #endif

    #ifndef WSASetLastError
    #define WSASetLastError(err) (errno = (err))
    #endif

    #ifndef WSAETIMEDOUT
    #define WSAETIMEDOUT ETIMEDOUT
    #endif

    #ifndef WSAEINVAL
    #define WSAEINVAL EINVAL
    #endif

    #ifndef WSAECONNRESET
    #define WSAECONNRESET ECONNRESET
    #endif

    #ifndef WSAEWOULDBLOCK
    #define WSAEWOULDBLOCK EWOULDBLOCK
    #endif

    #ifndef WSAEINPROGRESS
    #define WSAEINPROGRESS EINPROGRESS
    #endif

    #ifndef WSAECONNREFUSED
    #define WSAECONNREFUSED ECONNREFUSED
    #endif

    #ifndef WSAENETUNREACH
    #define WSAENETUNREACH ENETUNREACH
    #endif

    #ifndef WSAEHOSTUNREACH
    #define WSAEHOSTUNREACH EHOSTUNREACH
    #endif

    #ifndef WSAEAFNOSUPPORT
    #define WSAEAFNOSUPPORT EAFNOSUPPORT
    #endif

    #ifndef WSAEMSGSIZE
    #define WSAEMSGSIZE EMSGSIZE
    #endif
#endif

namespace Network {
namespace SocketIo {

inline bool SetNonBlocking(socket_t sock, bool nonBlocking) {
    if (sock == INVALID_SOCKET) return false;
#ifdef _WIN32
    u_long mode = nonBlocking ? 1 : 0;
    return ioctlsocket(sock, FIONBIO, &mode) == 0;
#else
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags == -1) return false;
    return fcntl(sock, F_SETFL, nonBlocking ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK)) == 0;
#endif
}

inline bool GetSocketError(socket_t sock, int* outError) {
    if (!outError || sock == INVALID_SOCKET) return false;
    int soError = 0;
    socklen_t optLen = sizeof(soError);
#ifdef _WIN32
    if (getsockopt(sock, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&soError), reinterpret_cast<int*>(&optLen)) != 0) {
        return false;
    }
#else
    if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &optLen) != 0) {
        return false;
    }
#endif
    *outError = soError;
    return true;
}

} // namespace SocketIo
} // namespace Network
