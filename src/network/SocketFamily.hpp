#pragma once
#include "PlatformSocket.hpp"

namespace Network {

enum class DualStackResult {
    NotApplicable,
    AlreadyEnabled,
    Enabled,
    Failed,
};

inline bool IsIpv4MappedAddress(const sockaddr_in6& address) {
    return IN6_IS_ADDR_V4MAPPED(&address.sin6_addr) != 0;
}

// 代理模式需要在 bind 前关闭 IPV6_V6ONLY，才能把 IPv4 代理端点表示为 v4-mapped IPv6 地址。
inline DualStackResult EnsureIpv6DualStack(socket_t socket, int addressFamily, int* errorCode = nullptr) {
    if (errorCode) *errorCode = 0;
    if (socket == INVALID_SOCKET || addressFamily != AF_INET6) {
        return DualStackResult::NotApplicable;
    }

    int v6Only = 1;
    socklen_t optionLength = static_cast<socklen_t>(sizeof(v6Only));
#ifdef _WIN32
    if (getsockopt(
            socket,
            IPPROTO_IPV6,
            IPV6_V6ONLY,
            reinterpret_cast<char*>(&v6Only),
            reinterpret_cast<int*>(&optionLength)) == SOCKET_ERROR) {
        if (errorCode) *errorCode = WSAGetLastError();
        return DualStackResult::Failed;
    }
#else
    if (getsockopt(
            socket,
            IPPROTO_IPV6,
            IPV6_V6ONLY,
            reinterpret_cast<void*>(&v6Only),
            &optionLength) == SOCKET_ERROR) {
        if (errorCode) *errorCode = WSAGetLastError();
        return DualStackResult::Failed;
    }
#endif
    if (v6Only == 0) return DualStackResult::AlreadyEnabled;

    const int disabled = 0;
#ifdef _WIN32
    if (setsockopt(
            socket,
            IPPROTO_IPV6,
            IPV6_V6ONLY,
            reinterpret_cast<const char*>(&disabled),
            static_cast<int>(sizeof(disabled))) == SOCKET_ERROR) {
        if (errorCode) *errorCode = WSAGetLastError();
        return DualStackResult::Failed;
    }
#else
    if (setsockopt(
            socket,
            IPPROTO_IPV6,
            IPV6_V6ONLY,
            reinterpret_cast<const void*>(&disabled),
            static_cast<socklen_t>(sizeof(disabled))) == SOCKET_ERROR) {
        if (errorCode) *errorCode = WSAGetLastError();
        return DualStackResult::Failed;
    }
#endif
    return DualStackResult::Enabled;
}

}  // namespace Network
