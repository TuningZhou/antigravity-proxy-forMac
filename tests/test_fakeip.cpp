// 回归测试在 Release 构建下也必须执行断言。
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string>

#include "network/PlatformSocket.hpp"
#include "network/FakeIP.hpp"

int main() {
    auto& fakeIp = Network::FakeIP::Instance();

    const std::string domain1 = "api.anthropic.com";
    const std::string domain2 = "chatgpt.com";

    // 1. 分配 FakeIP
    uint32_t ip1 = fakeIp.GetFakeIP(domain1);
    assert(ip1 != 0);
    assert(fakeIp.IsFakeIP(ip1));

    // 2. 幂等性：同一域名返回同一 FakeIP
    uint32_t ip1_again = fakeIp.GetFakeIP(domain1);
    assert(ip1 == ip1_again);

    // 3. 逆向查询：根据 FakeIP 获取原域名
    assert(fakeIp.GetDomain(ip1) == domain1);

    // 4. 不同域名分配不同 FakeIP
    uint32_t ip2 = fakeIp.GetFakeIP(domain2);
    assert(ip2 != 0);
    assert(ip2 != ip1);
    assert(fakeIp.IsFakeIP(ip2));
    assert(fakeIp.GetDomain(ip2) == domain2);

    // 5. 外部真实 IP 不被判定为 FakeIP (如 8.8.8.8)
    uint32_t realIp = (8 << 24) | (8 << 16) | (8 << 8) | 8;
    assert(!fakeIp.IsFakeIP(realIp));
    assert(fakeIp.GetDomain(realIp).empty());

    return 0;
}
