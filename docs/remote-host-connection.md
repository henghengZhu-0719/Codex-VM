# 远程 VM CLI（MacBook Air → Mac Pro）

## 推荐方式：直接 SSH 进入 VM

本模式不需要网页工作台、远程浏览器或 VPS 运行虚拟机。1C1G VPS 只需承担 EasyTier 网络服务。

1. Mac Pro 保持开机，先启动要连接的 Agent-VM 虚拟机。
2. 两台 Mac 加入相同 EasyTier 网络；Mac Pro 在「系统设置 → 通用 → 共享」启用远程登录。
3. Air 配置公钥 SSH 认证，并首次通过 `ssh USER@EASYTIER_IP` 手工验证主机指纹和 known_hosts。
4. Air 打开 Agent-VM → 设置 →「远程 VM · SSH 终端」，添加 Mac Pro 的 EasyTier IP 和 SSH 用户；工作台端口与 CLI 模式无关。
5. 在主机下选择一台运行中的 VM，点击「连接 VM」。列表显示远端应用里的别名，连接时使用 Lima 名称。系统 Terminal 会通过 SSH 连接 Mac Pro，再使用 Lima 的 ssh.config 进入 Linux VM。
6. 在 Linux Shell 内直接使用 `claude`、`codex`、`opencode` 等已安装的 CLI。

连接路径：Air Terminal → EasyTier SSH → Mac Pro SSH → Lima VM SSH → Linux CLI。

此方式不需要 Mac Pro 开启 HTTP 远程工作台。由于连接终端是普通交互式 SSH，断线可能结束前台 CLI 进程；需要保持会话时，请在 VM 内使用 tmux。

默认查找 Mac Pro 上的 ~/.agent-vm/lima/<VM名称>/ssh.config。如果 Mac Pro 使用自定义 AGENT_VM_STATE_DIR 或 AGENT_VM_LIMA_HOME，该入口需要相应适配。远程用户必须有权读取该 ssh.config。

安全：SSH 严格验证主机指纹、禁用代理转发与 X11 转发；VM 名称严格限定安全字符。旧网页工作台保留用于兼容，不是 CLI 模式的依赖。

---
# 远程主机连接（第一阶段）

本功能适用于 MacBook Air 作为客户端、另一台 Mac 作为 Agent-VM 运行主机。1C1G VPS 仅需承载 EasyTier 网络节点，不需要运行 VM。

## 能力范围

- 桌面客户端设置中可保存多个远程主机（名称、EasyTier IP、SSH 用户、端口）。
- 使用系统 OpenSSH，强制密钥认证、严格验证已知主机指纹，通过本机 `127.0.0.1` 转发远端工作台。
- 建立隧道后主动探测远端 `/api/state`（无凭据时预期 HTTP 401），确认工作台可达才显示已连接；可从主机列表重新打开工作台。
- SSH 连接失败、认证失败及远端工作台无法访问时会显示错误，不再在固定延迟后误报连接成功。
- 主机列表防止重复添加，并校验主机名、用户及端口；删除前需确认。
- 连接成功后打开系统浏览器，通过远端工作台访问口令查看/操作已有的 Agent 工作台。
- 已添加远程 VM 卡片，支持列出状态、资源信息和启动/停止；停止需要客户端二次确认，服务器再次核对 VM 存在及当前状态。
- 不复制远端 VM 磁盘、浏览器 Profile 或项目目录；原有本地 VM 操作不受影响。

**当前限制：**现有 RemoteWorkbenchServer 仅开放受限的 Agent/Codex 工作台操作和 VM 列表、启动、停止（非完整 VM 管理 API）。本阶段尚未实现远程 VM 创建/删除、完整 Linux 浏览器画面、SSH PTY 集成、独立 Server 守护进程或跨设备文件自动同步。SSH 隧道只在客户端 App 运行期间存活，断开后需要手动重连。远端 Mac 需要持续运行 Agent-VM App 并保持唤醒。

## 配置

1. Mac Pro 上启用 EasyTier，确认两台 Mac 能通过私有 IP 互访。
2. 在 Mac Pro 的系统设置开启「远程登录」(SSH)，仅允许可信账号登录。
3. 在 Air 上配置 **SSH 公钥登录**，首次通过交互式终端 `ssh USER@EASYTIER_IP` 确认真实主机指纹并存入 `known_hosts`。不要关闭主机指纹校验。
4. Mac Pro 的 Agent-VM 「设置」→「本机远程工作台」启用访问，使用随机令牌，不使用旧版本固定口令。远端工作台默认端口是 `18080`。
5. Air 的 Agent-VM 「设置」→「远程主机 · SSH」填写名称、EasyTier IP、SSH 用户名、SSH 端口和工作台端口，点击添加、连接。
6. 成功通过隧道探测后，浏览器打开 `http://127.0.0.1:<自动分配端口>/`，输入 Mac Pro 工作台中生成的口令。再次访问可点击「打开工作台」。

如果提示 SSH 已断开，先在 Air 的终端尝试 `ssh -o BatchMode=yes USER@EASYTIER_IP true`，确认密钥与主机指纹配置；如果提示无法访问远程工作台，在 Mac Pro 上确认已启用远程工作台，并检查监听端口。

**远程连接状态说明：**「已连接」仅表示 SSH 转发与工作台 HTTP 鉴权接口可达；不代表 VM、浏览器画面或终端等完整远程功能已经可用。

**注意：**远端工作台现有实现仍可能监听所有网络接口。应使用 Mac 防火墙/EasyTier ACL 限制 18080 的访问范围，不要在 VPS 上公网映射此端口。当前 HTTP 口令认证不能替代加密传输；应仅通过 SSH 隧道访问。避免在截图、日志或聊天中分享访问令牌。

## 下一阶段

- 完善共享 HostProvider，将 VM list/start/stop/create/remove 统一路由到本地或远端；目前仅通过认证远程工作台提供 list/start/stop。
- 远程原生终端（SSH PTY）、Agent 会话附着/恢复、浏览器安全转发。
- 对远程操作增加权限边界、运行状态确认及断线恢复。
- 将远端服务迁移为独立受认证的后台服务，明确与 GUI 会话的关系。

## 构建

本仓库的 macOS 桌面构建目前面向 Apple Silicon：

```bash
make
sh native-macos/build.sh
open "_output/Agent VM.app"
```

Linux 环境无法验证 SwiftUI/AppKit 的完整编译，请在 Apple Silicon Mac 上执行构建与真实连接验证。
