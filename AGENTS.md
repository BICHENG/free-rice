# AGENTS.md

给在这个仓库里安装、验证、接入或排错 free-rice 的 agent 看的操作说明。

## 动手之前

先跑 `rice doctor` 和 `rice status`，确认端口、网关和转发器的现状，再决定做什么。

这台机器上 3425、7999、7900、7901、9099 属于 free-rice。不要在这些端口起别的服务，也不要改端口。

需要改用户的客户端配置时，只改任务点名的那一份，改前在原目录留一个带时间戳的备份。别人的 DSH、Codex、Claude Code 配置不要顺手动。

`rice rotate` 会换出口，`rice probe` 会清冷却，`rice install` 会写文件并启动进程，`rice uninstall -Purge` 会删数据目录。执行前心里有数，执行后把结果贴出来。

## 安装

先看计划：

```powershell
.\rice.cmd install -DryRun -SubscriptionUrl "https://example.com/subscribe?token=..."
```

正式安装：

```powershell
.\rice.cmd install -SubscriptionUrl "https://example.com/subscribe?token=..."
if ($LASTEXITCODE -ne 0) { throw "install failed" }
```

本地 Clash YAML 也可以，把 `-SubscriptionUrl` 换成 `-ClashConfig .\clash.yaml`。无人值守时常用组合：

```powershell
$env:ZEN_IP_HOME = "D:\zen-ip"
.\rice.cmd install -ClashConfig .\clash.yaml -DataDir "D:\zen-ip" -NoStart -SkipTray -NoAutostart
```

参数含义：`-DataDir` 换数据目录；`-NoStart` 装完不启动；`-SkipTray` 不装托盘；`-NoAutostart` 不写登录自启；`-GatewayPath`/`-MihomoPath` 复用已有程序；`-MinContextTokens` 改过滤阈值；`-AllowModel` 加白名单；`-Probe` 安装后跑测速。

带 `-Probe` 安装时，测速前会先拉起 mihomo 和转发器；`-NoStart` 时测完停掉。Startup 目录不可写时，登录自启会落到 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `free-rice` 项。

安装不会改 DSH 的 profile。需要 DSH 接入时再单独执行 `magpie dsh`。

## 验证

按顺序看，失败就停在那一步。

```powershell
rice doctor                        # 端口、网关、插件 baseURL、日志
rice status                        # 可用 IP、当前出口、请求量
rice models                        # 当前提供的模型
rice info --json                   # 端点、端口、默认模型
```

发一条真实请求：

```powershell
$body = '{"model":"opencode-zen-free/minimax-m3.1-flash-free","messages":[{"role":"user","content":"只回复 OK"}],"max_tokens":64}'
(Invoke-RestMethod -Uri http://127.0.0.1:3425/v1/chat/completions -Method Post -Headers @{ Authorization = "Bearer magpie" } -ContentType "application/json" -Body $body -NoProxy).choices[0].message.content
```

返回内容里有 OK 就够了。


## 托盘和开始菜单

开始菜单的 `free-rice` 文件夹里有 start 和 tray 两个快捷方式。托盘和守护都是单实例，已在运行时再次启动会直接退出，不会出现两份在跑。

## 接 harness

所有客户端用同一组入口：OpenAI 兼容走 `http://127.0.0.1:3425/v1`，Anthropic 兼容走 `http://127.0.0.1:3425`，key 都是 `magpie`。模型名从 `rice models` 里取。

DSH：

```powershell
magpie dsh opencode-zen-free/minimax-m3.1-flash-free
```

Claude Code：

```powershell
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:3425"
$env:ANTHROPIC_API_KEY = "magpie"
```

Codex 在 `~/.codex/config.toml` 指向同样的 base_url，`wire_api = "responses"`。

OpenAI SDK 用 base_url `http://127.0.0.1:3425/v1` 和 api_key `magpie`；Cline、Roo、Continue、OpenWebUI、LobeChat 照填 base_url、key 和模型名。

## 排错

| 现象 | 先看 |
| --- | --- |
| 3425 不通 | `rice doctor`，magpie 是否退出 |
| 7999 不通 | `rice status`，`zen-supervisor.log` |
| 模型看不到 | `rice models`，`config.json` 的 minContextTokens、allow、deny |
| 请求返回 403 | 插件 baseURL 是否指向 7999，当前出口是否被地区限制 |
| 请求返回 429 | 上游额度用尽，等待重置 |
| 托盘红/黄 | `rice status`，悬浮总览里的事件 |
| 模型 404 | 模型名写错，用 `rice models` 里的全名 |

日志在 `%USERPROFILE%\.zen-ip`：`zen-router.log`、`zen-supervisor.log`、`install.log`。
