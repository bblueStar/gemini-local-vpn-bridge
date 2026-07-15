# Gemini 登录与本地 VPN 自动桥接（macOS）

## 问题是什么？

有些 macOS VPN 客户端只有“系统 HTTP/SOCKS 代理”。浏览器和不少应用会读取这个设置，但 Gemini Mac 的原生登录组件可能会绕过它、直接连接 Google OAuth 服务。若本地网络无法直连该服务，浏览器虽完成授权，Gemini 却会在“交换授权码”时超时。

## 思路

1. VPN 客户端在本机提供 SOCKS5 端口。
2. `sing-box` 创建 TUN 虚拟网卡，将原生应用的直连流量转给该 SOCKS5 端口。
3. 桥接服务持续检测 VPN 引擎真正连接的公网节点，把这些 IP 从 TUN 路由中排除，防止 VPN 自己被再次代理而形成断网循环。
4. 当切换节点导致出口 IP 改变时，服务自动重建 TUN 配置。

## 安装前条件

- Apple Silicon Mac，且 Gemini Mac 已安装。
- 已安装 Homebrew。
- VPN 客户端已连接，并对外提供本地 SOCKS5 端口。
- 你知道 VPN 核心进程的匹配路径和 SOCKS5 端口。

## 安装

1. 编辑 `settings.conf`：填写 `VPN_PROCESS_PATTERN`、`VPN_SOCKS_PORT`。
2. 在此目录运行：`chmod +x install.sh && ./install.sh`。
3. 脚本会安装 `sing-box`，并在最后请求一次 macOS 管理员密码创建开机自启服务。
4. 打开 VPN 并连接节点，再启动 Gemini 登录。

## 暂停、启动和排查

安装脚本使用的服务标签是 `com.example.gemini-local-proxy-bridge`：

```bash
# 暂停：停止 TUN，恢复普通系统代理模式
sudo launchctl bootout system/com.example.gemini-local-proxy-bridge

# 启动：恢复自动桥接
sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.gemini-local-proxy-bridge.plist
sudo launchctl kickstart -k system/com.example.gemini-local-proxy-bridge

# 查看日志
tail -f "$HOME/Library/Application Support/gemini-local-proxy-bridge/bridge.log"
```

暂停后 Gemini 的原生登录/联网可能再次失败，这是预期现象。服务在开机后会自动启动；录制截图或视频时可以先暂停，录完再启动。

如果安装后无法联网，先执行“暂停”命令恢复网络，再检查 `settings.conf` 中的 VPN 进程匹配路径和 SOCKS 端口。切勿在不了解网络影响的情况下把本工具用于公司设备或受管网络。

## 注意

- 这是针对“VPN 只提供本地 SOCKS、而目标应用不读系统代理”的兼容方案，不是所有 VPN 都需要。
- 自动节点检测依赖 VPN 的进程和本机网络行为；更理想的长期方案仍是使用原生 TUN 客户端并导入标准 Clash/sing-box 订阅。
- 不要把 VPN 订阅链接、账号、节点 IP 或日志中的令牌公开发布。
