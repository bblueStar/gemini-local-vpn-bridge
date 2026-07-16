# Gemini 登录与本地 VPN 自动桥接（macOS）

> 仅供排查“原生应用未遵循系统代理”的本地网络兼容问题。此项目不提供 VPN 节点、订阅、账号或绕过地区、组织及服务规则的方式；请自行确认所在地法律、公司政策与 Google/Gemini 的适用条款。

## 项目状态：仅供参考

本仓库保存的是一次特定 macOS 环境中的排查思路和参考实现，**不是适用于所有 VPN、所有 Mac 的一键安装工具**。不同客户端使用的代理协议、进程、端口、网卡和路由行为可能完全不同；直接套用别人的配置，可能造成全机断网、VPN 无法断开或无法重新连接。

当前脚本还没有作为面向公众的安装器完成安全审计。参考实现使用 root 权限创建 TUN，而配置和部分运行文件位于用户目录；在完成权限隔离前，不应直接用于生产设备或多人共用的 Mac。公开代码不包含作者的真实 VPN 配置，`settings.conf` 中的内容只是占位示例。

如果你遇到相同现象，建议先让熟悉 macOS 网络的人员或 AI 根据你的实际环境进行**只读诊断**。在确认 VPN 的工作方式、本地代理出口和恢复方法以前，不要安装脚本、创建 TUN 或修改系统路由。如果 VPN 本身提供官方 TUN、增强模式或虚拟网卡模式，应优先使用官方功能。

## 问题是什么？

有些 macOS VPN 客户端只有“系统 HTTP/SOCKS 代理”。浏览器和不少应用会读取这个设置，但 Gemini Mac 的原生登录组件可能会绕过它、直接连接 Google OAuth 服务。若本地网络无法直连该服务，浏览器虽完成授权，Gemini 却会在“交换授权码”时超时。

## 思路

1. VPN 客户端在本机提供 SOCKS5 端口。
2. `sing-box` 创建 TUN 虚拟网卡，将原生应用的直连流量转给该 SOCKS5 端口。
3. 桥接服务持续检测 VPN 引擎真正连接的公网节点，把这些 IP 从 TUN 路由中排除，防止 VPN 自己被再次代理而形成路由循环。
4. 服务不只检查端口监听，还会通过 SOCKS 发起短 HTTPS 健康检查。连续两次失败才撤销 TUN，既能识别“端口仍开着、代理实际已失效”，也能避免一次网络抖动造成频繁重启。

这不是给整个系统再套一层“万能 VPN”。它只解决一个特定断点：应用登录流程中的原生网络请求没有走现有的系统代理。桥接只有在“SOCKS 出口健康”且“已检测到 VPN 上游端点”时才会启动；任何一项消失都会停止 TUN，避免把不可用的本地 SOCKS 当作出口。

## 阅读和测试前提

- 你理解该实现会改变系统流量路径，并准备了恢复普通网络的方法。
- 已确认 VPN 的实际工作方式；不要假设每个 VPN 都提供 SOCKS5。
- 已确认本地代理不只是端口处于监听状态，而是能够完成真实的 HTTPS 请求。
- 已确认 VPN 核心进程、远端连接和 TUN 地址不会与现有路由冲突。
- 测试设备不是公司受管设备或多人共用的生产设备。

## 工作边界与网络影响

- `sing-box` 需要创建 TUN 虚拟网卡；安装和运行桥接服务需要管理员权限。
- 运行期间，符合 TUN 路由规则的流量会经由你配置的本地 SOCKS5 出口转发，可能影响其他原生应用的联网路径。
- 工具会读取匹配到的 VPN 进程的**当前 TCP 远端地址**，仅用于把 VPN 上游节点排除在 TUN 之外，以避免路由循环。端点会写入本机运行目录的 `endpoints.txt`；请勿分享该文件或日志。
- 它不收集、不上传账号、密码、OAuth 授权码、订阅链接或浏览历史。本仓库也不包含这些信息；但你的 VPN 客户端、`sing-box` 和 macOS 本身仍各自受其隐私政策与系统日志行为约束。

## 为什么不提供通用安装步骤

要让参考实现安全地用于另一台电脑，至少需要根据实际环境重新确认：

- VPN 是否真的提供本地 SOCKS5，以及地址和端口；
- VPN 核心进程的准确匹配方式；
- VPN 连接远端节点时使用的真实网络接口；
- TUN 地址、局域网和排除路由之间是否冲突；
- VPN 断开、重新连接和切换节点时的实际行为；
- root 服务的配置、日志、PID 和临时文件是否位于普通用户不可篡改的目录。

面向公众的正式安装器还应避免让 root 脚本直接 `source` 用户可写的配置文件，对主机、端口、URL 和进程匹配值进行严格校验，并把特权运行文件放在权限正确的系统目录。本仓库当前文件只用于帮助理解实现逻辑，不建议直接执行 `install.sh`。

## 已自行审计和适配后的操作参考

以下命令只适用于已经由你或专业人员完成安全审计、环境适配并安装的版本。它们不能证明当前参考代码适合直接安装。示例服务标签是 `com.example.gemini-local-proxy-bridge`：

暂停桥接并停止 TUN：

```bash
sudo launchctl bootout system/com.example.gemini-local-proxy-bridge
```

启动已经安装并完成适配的桥接：

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.gemini-local-proxy-bridge.plist
```

要求 launchd 立即重新启动服务：

```bash
sudo launchctl kickstart -k system/com.example.gemini-local-proxy-bridge
```

查看桥接日志：

```bash
tail -f "$HOME/Library/Application Support/gemini-local-proxy-bridge/bridge.log"
```

暂停后 Gemini 的原生登录/联网可能再次失败，这是预期现象。服务在开机后会自动启动；录制截图或视频时可以先暂停，录完再启动。

如果安装后无法联网，先执行“暂停”命令恢复网络，再检查 `settings.conf` 中的 VPN 进程匹配路径和 SOCKS 端口。切勿在不了解网络影响的情况下把本工具用于公司设备或受管网络。

如果 VPN 断开后再次连接提示“本地网络有问题”，先检查桥接日志是否有 `SOCKS exit is unhealthy; stopping bridge before VPN reconnect`。该行说明桥接已按预期撤销 TUN；若没有出现，确认进程路径、本地 SOCKS 地址和健康检查 URL。端口处于 LISTEN 并不代表代理出口可用。

## 卸载

以下命令会停止并移除本工具安装的 LaunchDaemon 与启动脚本；不会卸载 Homebrew 或 `sing-box`，也不会删除你的 VPN 客户端配置。

```bash
sudo launchctl bootout system/com.example.gemini-local-proxy-bridge 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.example.gemini-local-proxy-bridge.plist
sudo rm -f /usr/local/libexec/gemini-local-proxy-bridge.sh
rm -rf "$HOME/Library/Application Support/gemini-local-proxy-bridge"
```

## 注意

- 这是针对“VPN 只提供本地 SOCKS、而目标应用不读系统代理”的兼容方案，不是所有 VPN 都需要。
- 自动节点检测依赖 VPN 的进程和本机网络行为；更理想的长期方案仍是使用原生 TUN 客户端并导入标准 Clash/sing-box 订阅。
- 不要把 VPN 订阅链接、账号、节点 IP 或日志中的令牌公开发布。
- 公开提问或提交 issue 前，请使用“脱敏复现”：只提供 macOS 版本、`sing-box version`、报错时间与已打码日志片段。不要上传 `settings.conf`、`endpoints.txt`、完整日志或截图原图。
