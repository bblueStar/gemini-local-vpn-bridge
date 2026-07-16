# Gemini 登录与本地 VPN 自动桥接（macOS）

> 仅供排查“原生应用未遵循系统代理”的本地网络兼容问题。此项目不提供 VPN 节点、订阅、账号或绕过地区、组织及服务规则的方式；请自行确认所在地法律、公司政策与 Google/Gemini 的适用条款。

## 问题是什么？

有些 macOS VPN 客户端只有“系统 HTTP/SOCKS 代理”。浏览器和不少应用会读取这个设置，但 Gemini Mac 的原生登录组件可能会绕过它、直接连接 Google OAuth 服务。若本地网络无法直连该服务，浏览器虽完成授权，Gemini 却会在“交换授权码”时超时。

## 思路

1. VPN 客户端在本机提供 SOCKS5 端口。
2. `sing-box` 创建 TUN 虚拟网卡，将原生应用的直连流量转给该 SOCKS5 端口。
3. 桥接服务持续检测 VPN 引擎真正连接的公网节点，把这些 IP 从 TUN 路由中排除，防止 VPN 自己被再次代理而形成路由循环。
4. 服务不只检查端口监听，还会通过 SOCKS 发起短 HTTPS 健康检查。连续两次失败才撤销 TUN，既能识别“端口仍开着、代理实际已失效”，也能避免一次网络抖动造成频繁重启。

这不是给整个系统再套一层“万能 VPN”。它只解决一个特定断点：应用登录流程中的原生网络请求没有走现有的系统代理。桥接只有在“SOCKS 出口健康”且“已检测到 VPN 上游端点”时才会启动；任何一项消失都会停止 TUN，避免把不可用的本地 SOCKS 当作出口。

## 安装前条件

- Apple Silicon Mac，且 Gemini Mac 已安装。
- 已安装 Homebrew。
- VPN 客户端已连接，并对外提供本地 SOCKS5 端口。
- 你知道 VPN 核心进程的匹配表达式和 SOCKS5 端口。

## 工作边界与网络影响

- `sing-box` 需要创建 TUN 虚拟网卡；安装和运行桥接服务需要管理员权限。
- 运行期间，符合 TUN 路由规则的流量会经由你配置的本地 SOCKS5 出口转发，可能影响其他原生应用的联网路径。
- 工具会读取匹配到的 VPN 进程的**当前 TCP 远端地址**，仅用于把 VPN 上游节点排除在 TUN 之外，以避免路由循环。端点会写入本机运行目录的 `endpoints.txt`；请勿分享该文件或日志。
- 它不收集、不上传账号、密码、OAuth 授权码、订阅链接或浏览历史。本仓库也不包含这些信息；但你的 VPN 客户端、`sing-box` 和 macOS 本身仍各自受其隐私政策与系统日志行为约束。

## 安装

1. 编辑 `settings.conf`：填写 `VPN_PROCESS_PATTERN` 和 `VPN_SOCKS_PORT`。
2. 在此目录运行：`chmod +x install.sh && ./install.sh`。
3. 脚本会安装 `sing-box`，并在最后请求一次 macOS 管理员密码创建开机自启服务。
4. 打开 VPN 并连接节点，再启动 Gemini 登录。

安装器不会覆盖已存在的 `settings.conf`。首次运行会复制模板并停在确认提示前；编辑实际配置后，再次运行安装器并输入 `y`。

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

## 发布经验帖

可直接使用仓库内的 [经验帖发布素材](POST.md)。其中包含标题备选、正文、截图清单、录屏分镜和发布前脱敏检查表。
