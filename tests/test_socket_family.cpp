#include "network/PlatformSocket.hpp"

// 回归测试在 Release 构建下也必须执行断言。
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>

#include "network/SocketFamily.hpp"

int main() {
    socket_t socket6 = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
    assert(socket6 != INVALID_SOCKET);

    int error = 0;
    const Network::DualStackResult result =
        Network::EnsureIpv6DualStack(socket6, AF_INET6, &error);
    assert(result == Network::DualStackResult::Enabled ||
           result == Network::DualStackResult::AlreadyEnabled);
    assert(error == 0);

    int v6Only = 1;
    socklen_t optionLength = sizeof(v6Only);
    assert(getsockopt(
               socket6,
               IPPROTO_IPV6,
               IPV6_V6ONLY,
               &v6Only,
               &optionLength) == 0);
    assert(v6Only == 0);

    sockaddr_in6 mapped{};
    mapped.sin6_family = AF_INET6;
    mapped.sin6_addr.s6_addr[10] = 0xff;
    mapped.sin6_addr.s6_addr[11] = 0xff;
    mapped.sin6_addr.s6_addr[12] = 127;
    mapped.sin6_addr.s6_addr[15] = 1;
    assert(Network::IsIpv4MappedAddress(mapped));

    sockaddr_in6 native{};
    native.sin6_family = AF_INET6;
    native.sin6_addr = in6addr_loopback;
    assert(!Network::IsIpv4MappedAddress(native));

    closesocket(socket6);
    return 0;
}
