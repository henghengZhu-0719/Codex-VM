# Agent VM

为每个项目创建独立的 Linux 虚拟机，让 AI 编程助手在 VM 内安装依赖、运行命令和修改项目。

本仓库基于 [sylvinus/agent-vm](https://github.com/sylvinus/agent-vm)，增加了原生 macOS 客户端、项目挂载查询、额外共享目录管理，以及安装流程优化。既可以使用桌面界面，也可以直接运行命令行。

## 功能

| 功能 | 说明 |
| --- | --- |
| 项目独立环境 | 每个项目使用自己的 VM，从基础模板创建 |
| macOS 客户端 | 选择项目、配置资源、创建与启动 VM、查看状态及日志、打开终端 |
| AI 编程助手 | 按需安装 Codex、Claude Code、OpenCode、Mistral Vibe、Pi |
| 开发工具 | 可选 Python、Node.js、Docker、Chromium、GitHub CLI 等组件 |
| 浏览器编辑器 | 可选 code-server，通过 `agent-vm code` 打开 |
| 共享目录 | 查看主机与 VM 的目录映射，添加只读或读写共享目录 |
| 文件保护 | 默认保护共享中的 `.git`、`.hg`，部分敏感文件写入需确认 |

命令行支持 macOS 和 Linux，Windows 支持仍为实验性。当前桌面客户端构建脚本面向 **Apple Silicon Mac，macOS 13 或更高版本**。

## 从源码构建

需要 Git、Make 和满足 [go.mod](go.mod) 要求的 Go 工具链。macOS 还需要 Xcode Command Line Tools。首次构建和创建基础模板需要下载依赖及系统软件包。

```bash
git clone https://github.com/henghengZhu-0719/Codex-VM.git
cd Codex-VM
make
```

命令行程序生成在 `_output/bin/agent-vm`。安装到 PATH：

```bash
./agent-vm.sh install
```

本项目依赖 `third_party/` 中的本地补丁，请从源码构建，不能通过 `go install ...@latest` 构建。上游安装脚本和软件包提供的是上游版本，本仓库新增功能请使用这里的源码。

## macOS 桌面界面（React + SwiftUI）

主窗口采用 SwiftUI + WKWebView 原生外壳，内部由 React 实现虚拟机卡片、AI 额度、代理与设置页面；菜单栏由 SwiftUI 原生管理。底层 Go/Lima 虚拟机核心保持不变。视觉设计采用 [awesome-design-md](https://github.com/VoltAgent/awesome-design-md) 中 Apple 与 Linear 的设计原则。

需要 **Node.js 22** 来构建 React 静态资源。运行中的 App 不需要 Node、Vite 服务或浏览器网络依赖。

详细架构、构建方法与安全边界见 [React 桌面迁移说明](docs/react-desktop-migration.md)。

## macOS 客户端

在 Apple Silicon Mac 上，从仓库根目录运行：

```bash
make
sh native-macos/build.sh
open "_output/Agent VM.app"
```

构建脚本将 CLI 打包进 App 并进行本地签名。应用默认使用内置程序，也可通过 `AGENT_VM_BINARY` 环境变量指定其他可执行文件。

1. 选择项目文件夹，设置 CPU、内存和磁盘大小。
2. 按需启用浏览器编辑器、代理和地区同步。
3. 创建环境：默认复用已有基础模板，也可选择重建；新建模板默认安装 Codex 和 code-server。
4. 在列表中启动、停止或删除 VM，查看挂载目录，打开 Terminal。

默认资源为 1 个 CPU、3 GB 内存、10 GB 磁盘；创建时选择 code-server 会将内存至少设为 4 GB。资源选项用于新建 VM，已有 VM 不会通过此流程调整配置。重建基础模板也不会自动替换已有项目 VM。

桌面客户端会自动启动运行中虚拟机的 Web Code。卡片显示可直接打开的链接，「更多操作」中也可打开 Web Code。默认通过 Mac 的局域网地址提供带密码登录的访问；退出 App 后关闭内网转发，重新打开 App 会恢复。没有可用局域网地址时使用本机链接。已有模板未安装 code-server 时，卡片会显示启动失败原因。

### 共享目录

客户端在创建或启动环境时，会准备主机目录 `~/AgentVM-Shared`，将其以读写方式映射到 VM 内的 `/mnt/agent-vm-shared`。额外的项目共享目录可在界面中按只读或读写方式添加。

配置保存在 `~/.agent-vm/volumes`。修改后需重启对应 VM；客户端添加的项目目录可以通过客户端移除。

### 代理

当前客户端默认启用固定代理 `http://10.126.126.1:8787`，并添加对应网络放行规则。如果你的环境没有这个代理，请在创建或启动 VM 前关闭代理选项。代理地址目前写在客户端源码中，尚不支持在界面内修改。

## 命令行快速开始

先创建基础模板，再进入项目目录启动助手：

```bash
agent-vm setup
cd /path/to/your-project
agent-vm codex
```

也可以直接指定预装组件，跳过交互向导：

```bash
# 安装 Codex 及其需要的 Node.js
agent-vm setup --preinstall=codex

# 安装默认开发工具，以及 OpenCode 浏览器编辑器扩展
agent-vm setup --preinstall=default,code-opencode
```

常用命令在项目目录下执行：

| 命令 | 用途 |
| --- | --- |
| `agent-vm shell` | 进入项目 VM 的 Shell |
| `agent-vm run npm test` | 在 VM 内执行项目命令 |
| `agent-vm claude` | 启动 Claude Code，需先安装对应组件 |
| `agent-vm opencode` | 启动 OpenCode，需先安装对应组件 |
| `agent-vm code` | 打开浏览器编辑器，需先安装 code-server |
| `agent-vm list` | 查看 VM 列表 |
| `agent-vm stop` | 停止当前项目 VM |
| `agent-vm rm` | 删除当前项目 VM 及其虚拟磁盘 |
| `agent-vm doctor` | 检查环境并显示诊断建议 |
| `agent-vm --readonly shell` | 以主机共享目录只读的方式进入 VM |
| `agent-vm --scratch codex` | 不挂载主机目录，运行结束后删除临时 VM |

删除 VM 不会删除主机上的项目目录，但 VM 虚拟磁盘中未另行保存的数据会丢失。

### 管理额外挂载

```bash
# 获取当前项目 VM 的名称
agent-vm name

# 将 my-vm 替换为实际名称，路径使用主机上的绝对路径
agent-vm vm-mounts my-vm
agent-vm vm-volume add my-vm /absolute/path/to/data ro
agent-vm vm-volume add my-vm /absolute/path/to/output rw
agent-vm vm-volume remove my-vm /absolute/path/to/output rw
```

`vm-mounts` 输出 JSON 目录映射。`ro` 表示只读，`rw` 表示读写；移除时路径和权限需与添加时一致。`vm-volume` 仅移除通过这套管理功能添加的项目规则。保存后停止并重新启动 VM，使变更生效。

## 文件与网络边界

AI 助手在 VM 中具有较高权限，也能访问网络。主机项目目录默认可写，VM 内的修改会直接体现在主机文件上。客户端配置的公共共享目录、手动添加的目录也会扩大 VM 可访问的范围。

- 共享中的 `.git`、`.hg` 和项目内 Git hooks 目录默认由主机侧文件服务保护；提交与推送在主机上完成。
- `.envrc`、`.vscode/tasks.json` 等可能被主机执行的文件受写入确认机制保护，规则位于 `~/.agent-vm/guarded`。
- VM 默认可访问互联网，对主机及局域网的访问由 `~/.agent-vm/network` 控制。客户端启用代理时会添加代理放行规则。
- 在主机编辑器中打开项目时，需留意自动任务、插件及提交钩子对项目文件的执行。终端连接请使用可信的客户端配置。

## 开发

```bash
make                                           # 构建 CLI
make test-go                                   # Go 单元测试，无需启动 VM
go test -tags e2e ./internal/vm/ ./internal/cli/  # 使用真实 VM 的集成测试
make check-third-party test-third-party         # 校验第三方补丁并测试
sh native-macos/build.sh                        # 构建 macOS App，先完成 make
```

| 路径 | 内容 |
| --- | --- |
| `native-macos/` | SwiftUI 客户端与 App 构建脚本 |
| `cmd/` | 命令行程序入口 |
| `internal/cli/` | CLI 命令、安装流程和挂载管理 |
| `agent-vm.setup.sh` | VM 内软件安装脚本 |
| `third_party/`、`patches/` | 第三方源码与本地补丁 |
| `www/` | 文档网站源码 |

## 更多文档

- [更新记录](CHANGELOG.md)：上游版本历史。
- [发布流程](RELEASING.md)：构建与发布说明。
- [第三方补丁](patches/README.md)：依赖修改说明。
- [网站开发](www/README.md)：文档站点维护方式。
- [上游文档](https://www.agent-vm.org/)：通用命令、配置与设计说明；本仓库新增功能以源码及本文为准。

## 许可证

沿用上游的 [MIT 许可证](LICENSE)。原作者及第三方组件声明见 [NOTICE](NOTICE) 和 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。
