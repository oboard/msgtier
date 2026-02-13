#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#ifdef _WIN32
    #include <winsock2.h>
    #include <iphlpapi.h>
    #include <ws2tcpip.h>
    #pragma comment(lib, "iphlpapi.lib")
    #pragma comment(lib, "ws2_32.lib")
    #define close closesocket
#else
    #include <unistd.h>
    #include <sys/socket.h>
    #include <sys/ioctl.h>
    #include <net/if.h>
    #include <arpa/inet.h>
    #include <ifaddrs.h>
    #include <netinet/in.h>
    #include <netdb.h>
#endif

#include "moonbit.h"

#define MAX_IP_LENGTH 46  // IPv6 最大长度
#define MAX_INTERFACES 64

typedef struct {
    char name[32];
    char ip[MAX_IP_LENGTH];
    bool is_up;
    bool is_loopback;
    bool is_virtual;
} InterfaceInfo;

/**
 * 判断是否为虚拟网卡（根据常见命名规则）
 */
bool is_virtual_interface(const char *name) {
    // 常见虚拟网卡前缀
    const char *virtual_prefixes[] = {
        "lo",      // Linux/macOS 回环
        "docker",  // Docker
        "br-",     // Linux bridge
        "veth",    // Linux virtual ethernet
        "virbr",   // KVM/libvirt
        "vmnet",   // VMware
        "vboxnet", // VirtualBox
        "awdl",    // Apple Wireless Direct Link
        "utun",    // macOS VPN tunnel
        "gif",     // Generic tunnel interface
        "stf",     // IPv6 tunnel
        "llw",     // Low-latency WAN
        "bridge",  // macOS bridge
        "p2p",     // P2P interface
        NULL
    };
    
    for (int i = 0; virtual_prefixes[i] != NULL; i++) {
        if (strncmp(name, virtual_prefixes[i], strlen(virtual_prefixes[i])) == 0) {
            return true;
        }
    }
    return false;
}

/**
 * 获取网卡优先级（用于排序）
 * 优先级：物理网卡 > WiFi > 其他
 */
#ifdef _WIN32
/**
 * Windows: 获取所有网卡信息
 */
int get_all_interfaces(InterfaceInfo *interfaces, int max_count) {
    WSADATA wsaData;
    PIP_ADAPTER_ADDRESSES pAddresses = NULL;
    ULONG outBufLen = 0;
    DWORD dwRetVal = 0;
    int count = 0;
    
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        return 0;
    }
    
    // 获取所需缓冲区大小
    dwRetVal = GetAdaptersAddresses(AF_UNSPEC, 
                                    GAA_FLAG_INCLUDE_PREFIX | GAA_FLAG_INCLUDE_GATEWAYS, 
                                    NULL, NULL, &outBufLen);
    if (dwRetVal != ERROR_BUFFER_OVERFLOW) {
        WSACleanup();
        return 0;
    }
    
    pAddresses = (IP_ADAPTER_ADDRESSES *)malloc(outBufLen);
    if (pAddresses == NULL) {
        WSACleanup();
        return 0;
    }
    
    dwRetVal = GetAdaptersAddresses(AF_UNSPEC,
                                    GAA_FLAG_INCLUDE_PREFIX | GAA_FLAG_INCLUDE_GATEWAYS,
                                    NULL, pAddresses, &outBufLen);
    if (dwRetVal != NO_ERROR) {
        free(pAddresses);
        WSACleanup();
        return 0;
    }
    
    PIP_ADAPTER_ADDRESSES pCurr = pAddresses;
    while (pCurr && count < max_count) {
        PIP_ADAPTER_UNICAST_ADDRESS pUnicast = pCurr->FirstUnicastAddress;
        while (pUnicast && count < max_count) {
            int family = pUnicast->Address.lpSockaddr->sa_family;
            if (family == AF_INET || family == AF_INET6) {
                InterfaceInfo *info = &interfaces[count];
                memset(info, 0, sizeof(InterfaceInfo));

                WideCharToMultiByte(CP_UTF8, 0, pCurr->FriendlyName, -1,
                                    info->name, sizeof(info->name), NULL, NULL);
                info->is_up = (pCurr->OperStatus == IfOperStatusUp);
                info->is_loopback = (pCurr->IfType == IF_TYPE_SOFTWARE_LOOPBACK);

                if (pCurr->IfType == IF_TYPE_TUNNEL ||
                    strstr(info->name, "Virtual") != NULL ||
                    strstr(info->name, "VMware") != NULL ||
                    strstr(info->name, "VirtualBox") != NULL) {
                    info->is_virtual = true;
                }

                if (family == AF_INET) {
                    SOCKADDR_IN *addr =
                        (SOCKADDR_IN *)pUnicast->Address.lpSockaddr;
                    inet_ntop(AF_INET, &(addr->sin_addr), info->ip,
                              sizeof(info->ip));
                } else {
                    SOCKADDR_IN6 *addr =
                        (SOCKADDR_IN6 *)pUnicast->Address.lpSockaddr;
                    inet_ntop(AF_INET6, &(addr->sin6_addr), info->ip,
                              sizeof(info->ip));
                }

                if (info->ip[0] != '\0') {
                    count++;
                }
            }
            pUnicast = pUnicast->Next;
        }
        pCurr = pCurr->Next;
    }
    
    free(pAddresses);
    WSACleanup();
    return count;
}

#else
/**
 * Linux/macOS/BSD: 获取所有网卡信息
 */
int get_all_interfaces(InterfaceInfo *interfaces, int max_count) {
    struct ifaddrs *ifap = NULL, *ifa = NULL;
    int count = 0;
    
    if (getifaddrs(&ifap) == -1) {
        perror("getifaddrs");
        return 0;
    }
    
    for (ifa = ifap; ifa != NULL && count < max_count; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL) continue;
        
        int family = ifa->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6) continue;
        
        InterfaceInfo *info = &interfaces[count];
        memset(info, 0, sizeof(InterfaceInfo));
        strncpy(info->name, ifa->ifa_name, sizeof(info->name) - 1);
        
        if (family == AF_INET) {
            struct sockaddr_in *addr = (struct sockaddr_in *)ifa->ifa_addr;
            inet_ntop(AF_INET, &(addr->sin_addr), info->ip, sizeof(info->ip));
        } else {
            struct sockaddr_in6 *addr = (struct sockaddr_in6 *)ifa->ifa_addr;
            inet_ntop(AF_INET6, &(addr->sin6_addr), info->ip, sizeof(info->ip));
        }
        
        // 检查状态
        info->is_up = (ifa->ifa_flags & IFF_UP) && (ifa->ifa_flags & IFF_RUNNING);
        info->is_loopback = (ifa->ifa_flags & IFF_LOOPBACK);
        info->is_virtual = is_virtual_interface(info->name);
        
        count++;
    }
    
    freeifaddrs(ifap);
    return count;
}
#endif

/**
 * 按优先级排序网卡
 */
/**
 * 列出所有网卡信息
 */
void list_all_interfaces() {
    InterfaceInfo interfaces[MAX_INTERFACES];
    int count = get_all_interfaces(interfaces, MAX_INTERFACES);
    
    for (int i = 0; i < count; i++) {
        InterfaceInfo *info = &interfaces[i];
        const char *status = info->is_up ? "UP" : "DOWN";
        const char *type = "physical";
        if (info->is_loopback) type = "loopback";
        else if (info->is_virtual) type = "virtual";
        
        printf("%-15s %-20s %-8s %-10s\n",
               info->name, info->ip, status, type);
    }
}

MOONBIT_FFI_EXPORT moonbit_bytes_t *loip_list_interfaces_ffi(void) {
    InterfaceInfo interfaces[MAX_INTERFACES];
    int count = get_all_interfaces(interfaces, MAX_INTERFACES);

    moonbit_bytes_t *result =
        (moonbit_bytes_t *)moonbit_make_ref_array(count, NULL);
    if (result == NULL) {
        return NULL;
    }

    for (int i = 0; i < count; i++) {
        InterfaceInfo *info = &interfaces[i];
        const char *status = info->is_up ? "UP" : "DOWN";
        const char *type = "Physical";
        if (info->is_loopback) type = "Loopback";
        else if (info->is_virtual) type = "Virtual";

        char line[128];
        int len = snprintf(line, sizeof(line), "%-15s %-20s %-8s %-10s",
                           info->name, info->ip, status, type);
        if (len < 0) {
            len = 0;
        }
        if (len >= (int)sizeof(line)) {
            len = (int)sizeof(line) - 1;
        }
        moonbit_bytes_t item = moonbit_make_bytes(len, 0);
        memcpy(item, line, (size_t)len);
        result[i] = item;
    }

    return result;
}
