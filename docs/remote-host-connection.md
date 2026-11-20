# 远程主机连接（第一阶段）

本功能适用于 MacBook Air 作为客户端、另一台 Mac 作为 Agent-VM 运行主机。1C1G VPS 仅需承载 EasyTier 网络节点，不需要运行 VM。

## 能力范围

- 桌面客户端设置中可保存多个远程主机（名称、EasyTier IP、SSH 用户、端口）。
- 使用系统 OpenSSH，强制密钥认证、严格验证已知主机指纹，通过本机 `127.0.0.1` 转发远端工作台。
- 连接成功后打开系统浏览器，通过远端工作台访问口令查看/操作已有的 Agent 工作台。
- 不复制远端 VM 磁盘、浏览器 Profile 或项目目录；原有本地 VM 操作不受影响。

**当前限制：**现有 RemoteWorkbenchServer 仅开放受限的 Agent/Codex 工作台操作（非完整 VM 管理 API）。本阶段尚未实现远程 VM 卡片的创建/启动/停止、完整 Linux 浏览器画面、SSH PTY 集成、独立 Server 守护进程或跨设备文件自动同步。SSH 隧道只在客户端 App 运行期间存活。远端 Mac 需要持续运行 Agent-VM App 并保持唤醒。

## 配置

1. Mac Pro 上启用 EasyTier，确认两台 Mac 能通过私有 IP 互访。
2. 在 Mac Pro 的系统设置开启「远程登录」(SSH)，仅允许可信账号登录。
3. 在 Air 上配置 **SSH 公钥登录**，首次通过交互式终端 `ssh USER@EASYTIER_IP` 确认真实主机指纹并存入 `known_hosts`。不要关闭主机指纹校验。
4. Mac Pro 的 Agent-VM 「设置」→「本机远程工作台」启用访问，使用随机令牌，不使用旧版本固定口令。远端工作台默认端口是 `18080`。
5. Air 的 Agent-VM 「设置」→「远程主机 · SSH」填写名称、EasyTier IP、SSH 用户名、SSH 端口和工作台端口，点击添加、连接。
6. 浏览器在 `http://127.0.0.1:<随机端口>/` 打开后，输入 Mac Pro 工作台中生成的口令。

**注意：**远端工作台现有实现仍可能监听所有网络接口。应使用 Mac 防火墙/EasyTier ACL 限制 18080 的访问范围，不要在 VPS 上公网映射此端口。当前 HTTP 口令认证不能替代加密传输；应仅通过 SSH 隧道访问。避免在截图、日志或聊天中分享访问令牌。

## 下一阶段

- 引入共享 HostProvider，将 VM list/start/stop/create/remove 统一路由到本地或远端。
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
