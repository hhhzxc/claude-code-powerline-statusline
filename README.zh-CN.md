# Claude Code Powerline 状态栏

[English README](README.md)

这是一个 **纯本地、零 API 请求** 的 Claude Code 双行 powerline 状态栏。它会显示当前模型、思考强度、上下文占用、会话总花费、限额用量，并估算这笔花费在 Write / Output / Cache 三类中的拆分。

脚本不会请求任何外部 API 或服务，只读取 Claude Code 在本地传入的 statusline JSON 和 transcript 路径。

## 效果预览

![Claude Code Powerline 状态栏预览](assets/preview.png)

```text
 Opus 4.8 > high > 660.0K/1000K 66%            $34.50 > 5h 21% > 7d 3%
 Write $5.61 (16%) > Out $7.54 (22%) > Cache $21.35 (62%)
```

预览里的 `>` 只是纯文本替代符；实际脚本会渲染 powerline 三角箭头。

## 隐私与账号行为

这个状态栏是完全本地的。它只解析 Claude Code 已经在本机提供的 statusline JSON 和 transcript 文件，然后在本地终端渲染状态栏。

它不会请求 Anthropic API，不上传遥测数据，也不会在你正在运行的 Claude Code 会话之外产生额外 token 消耗或额外的 Anthropic 账号侧请求行为。

## 文件说明

| 文件 | 作用 |
|---|---|
| `statusline-powerline.sh` | 状态栏主脚本。读取 Claude Code 从 stdin 传入的 statusline JSON，并渲染双行输出。 |
| `statusline-stop.sh` | Stop 钩子。每轮结束后扫描主 transcript 和子代理 transcript，写入本地成本拆分快照。 |
| `settings-snippet.json` | Claude Code 配置片段，包含 `statusLine` 和 `hooks.Stop`。 |

运行期会自动生成本地快照：

```text
~/.claude/statusline-tokens-<session_id>.json
```

这些文件很小，超过 30 天未更新会自动清理。

## 兼容性

支持的环境：

| 平台 | 支持方式 |
|---|---|
| macOS | 系统默认 `/bin/bash` 3.2 或更新版本，另需 `jq` |
| Linux | Bash 3.2 或更新版本，另需 `jq` |
| Windows | Git Bash，另需 `jq`；有 `cygpath` 时会自动用它转换路径 |

其它命令都是 macOS / Linux / Git Bash 常见基础工具：`awk`、`tr`、`find`、`cat`、`printf`、`mv`、`rm`。

如果缺少 `jq`，按平台安装：

```bash
# macOS
brew install jq

# Debian / Ubuntu
sudo apt-get install jq

# Fedora
sudo dnf install jq

# Arch Linux
sudo pacman -S jq
```

Windows 用户需要安装 Git for Windows，并确保 Git Bash 里能直接运行 `bash` 和 `jq`。如果 Claude Code 需要显式指定 Git Bash 路径，可以把 `CLAUDE_CODE_GIT_BASH_PATH` 设为你的 `bash.exe` 路径。

macOS 用户如果通过 Homebrew 安装 `jq`，脚本已经自动把 `/opt/homebrew/bin` 和 `/usr/local/bin` 加到 `PATH` 前面，所以即使 Claude Code 不是从交互式终端启动，也能更稳定地找到 `jq`。

终端字体建议使用 Cascadia Code PL、MesloLGS NF、JetBrainsMono Nerd Font 或其它 Nerd Font，否则 powerline 三角箭头可能显示成方框。

## 安装

克隆仓库：

```bash
git clone https://github.com/hhhzxc/claude-code-powerline-statusline.git
cd claude-code-powerline-statusline
```

把脚本复制到 Claude 配置目录：

```bash
mkdir -p ~/.claude
cp statusline-powerline.sh statusline-stop.sh ~/.claude/
chmod +x ~/.claude/statusline-powerline.sh ~/.claude/statusline-stop.sh
```

把下面配置合并进 `~/.claude/settings.json`。如果文件里已经有其它配置，请保留原有键，只加入这两段。

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-powerline.sh"
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/statusline-stop.sh"
          }
        ]
      }
    ]
  }
}
```

修改 `settings.json` 后需要重启 Claude Code。状态栏脚本本身会实时读取，但 Stop hook 需要在 Claude Code 启动时注册。

## 工作原理

```text
Claude Code -- statusline JSON via stdin --> statusline-powerline.sh --> output
                                               |
                                               v
                         ~/.claude/statusline-tokens-<session_id>.json
                                               ^
                                               |
Claude Code -- Stop hook at turn end ----> statusline-stop.sh
```

第一行使用 Claude Code 实时传入的 statusline JSON：

| 显示 | 来源 |
|---|---|
| 模型 | `.model.display_name` 或 `.model.id` |
| 思考强度 | `.effort.level` |
| 上下文用量 | `.context_window.*` |
| 总花费 | `.cost.total_cost_usd` |
| 限额 | `.rate_limits.five_hour.*` 和 `.rate_limits.seven_day.*` |

第二行使用 `statusline-stop.sh` 写入的快照。Stop hook 会读取主 transcript 和子代理 transcript，并累计三类成本权重：

| 类别 | 含义 |
|---|---|
| Write | 输入 token 和缓存写入 token |
| Out | 输出 token |
| Cache | 缓存读取 token |

总花费始终来自 Claude Code 自己提供的 `.cost.total_cost_usd`。脚本里硬编码的模型价格只用于估算这个总花费在 Write / Output / Cache 三类中的分配比例。

## 模型价格维护

模型价格选择硬编码，是为了让脚本保持零依赖、纯本地、易复制。Claude 新增或改名模型后，需要同时更新两个脚本。

在 `statusline-powerline.sh` 里，更新 fallback 价格表：

```bash
case "$model_id" in
  *new-model*) P_IN=3; P_OUT=15; P_CR=0.3; P_W5=3.75; P_W1=6 ;;
esac
```

所有数值单位都是 USD / 百万 token：

| 变量 | 含义 |
|---|---|
| `P_IN` | 输入 token 价格 |
| `P_OUT` | 输出 token 价格 |
| `P_CR` | 缓存读取 token 价格 |
| `P_W5` | 5 分钟缓存写入 token 价格 |
| `P_W1` | 1 小时缓存写入 token 价格 |

在 `statusline-stop.sh` 里，更新 `pin($m)` 函数，填入该模型的输入价格，单位同样是 USD / 百万 token：

```jq
elif ($x|test("new-model";"i")) then 3
```

Stop hook 目前假设 Anthropic 当前倍率规则如下：

| 项目 | 倍率 |
|---|---|
| 输出 | 输入价格 x 5 |
| 缓存读取 | 输入价格 x 0.1 |
| 5 分钟缓存写入 | 输入价格 x 1.25 |
| 1 小时缓存写入 | 输入价格 x 2 |

如果未来某个模型使用不同倍率，还需要同步修改 `statusline-stop.sh` 里的计算公式。

无法识别的模型会按 Opus 档位估算拆分比例。总花费仍然使用 Claude Code 报告的权威值。

## 手动测试

用示例输入测试主脚本：

```bash
printf '%s\n' '{"model":{"display_name":"claude-opus-4-8","id":"claude-opus-4-8"},"effort":{"level":"high"},"cost":{"total_cost_usd":34.5},"context_window":{"used_percentage":66,"context_window_size":1000000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":300,"cache_read_input_tokens":4000}},"rate_limits":{"five_hour":{"used_percentage":21},"seven_day":{"used_percentage":3}},"session_id":"sample-session"}' \
  | bash ./statusline-powerline.sh
```

检查脚本语法：

```bash
bash -n ./statusline-powerline.sh
bash -n ./statusline-stop.sh
```

运行完整 smoke test：

```bash
bash tests/smoke.sh
```

仓库里也包含 GitHub Actions 工作流，会在 Ubuntu 和 macOS 上自动运行这套 smoke test。

## 自定义

编辑 `statusline-powerline.sh`：

| 想改的内容 | 位置 |
|---|---|
| 左右两组间距 | `gap=$(printf '%*s' 24 '')` |
| 配色 | `BG_*` 变量 |
| 显示字段 | `L_TX`、`R_TX`、`L2_TX` 数组 |
| 分隔符字形 | `SEP=$'\xee\x82\xb0'` |

## 故障排查

| 现象 | 处理方式 |
|---|---|
| 三角箭头显示成方框 | 换成支持 powerline 字形的字体。 |
| 第二行拆分一直不更新 | 重启 Claude Code，让 Stop hook 正确注册。 |
| 上下文显示 `--K` | 当前 Claude Code 版本可能没有提供 `context_window` 字段。 |
| 状态栏完全不显示 | 检查 `statusLine.command` 路径，并确认 `bash` 和 `jq` 可用。 |
| macOS 找不到 `jq` | 先执行 `brew install jq`；脚本已内置常见 Homebrew 路径兜底。 |
| Windows 路径异常 | 在 Git Bash 环境下运行，并确认 `cygpath` 可用。 |

## 协议

MIT。见 [LICENSE](LICENSE)。
