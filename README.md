# Claude Code Powerline Statusline

[中文说明](README.zh-CN.md)

A local-only two-line powerline statusline for Claude Code. It shows the active
model, thinking effort, context usage, session cost, rate-limit usage, and an
estimated Write / Output / Cache cost split.

The scripts do not call any API or external service. They only read the JSON
payload and transcript paths that Claude Code provides locally.

## Preview

![Claude Code Powerline Statusline preview](assets/preview.png)

## Privacy And Account Behavior

This statusline is fully local. It parses the statusline JSON and transcript
files that Claude Code already provides on your machine, then renders a local
terminal statusline.

It does not send requests to the Anthropic API, does not upload telemetry, and
does not create extra token usage or extra Anthropic-side account activity
beyond the Claude Code session you are already running.

## Files

| File | Purpose |
|---|---|
| `statusline-powerline.sh` | Main statusline command. It reads Claude Code statusline JSON from stdin and renders the two-line output. |
| `statusline-stop.sh` | Stop hook. At the end of each turn, it scans the main transcript and sub-agent transcripts, then writes a local cost-split snapshot. |
| `settings-snippet.json` | Example Claude Code settings snippet containing `statusLine` and `hooks.Stop`. |

Runtime snapshots are written to:

```text
~/.claude/statusline-tokens-<session_id>.json
```

They are tiny local files and are cleaned up after 30 days.

## Compatibility

Supported shells:

| Platform | Supported setup |
|---|---|
| macOS | Default `/bin/bash` 3.2 or newer, plus `jq` |
| Linux | Bash 3.2 or newer, plus `jq` |
| Windows | Git Bash, plus `jq`; `cygpath` is used when available |

Other required command-line tools are standard on macOS/Linux/Git Bash:
`awk`, `tr`, `find`, `cat`, `printf`, `mv`, and `rm`.

Install `jq` if it is missing:

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

On Windows, install Git for Windows and make sure `bash` and `jq` are available
inside Git Bash. If Claude Code needs an explicit Git Bash path, set
`CLAUDE_CODE_GIT_BASH_PATH` to your `bash.exe`.

On macOS, the scripts prepend `/opt/homebrew/bin` and `/usr/local/bin` to `PATH`
so `jq` installed by Homebrew is found even when Claude Code is launched outside
an interactive terminal.

Use a terminal font with powerline glyphs, such as Cascadia Code PL, MesloLGS
NF, JetBrainsMono Nerd Font, or another Nerd Font.

## Installation

Clone the repository:

```bash
git clone https://github.com/hhhzxc/claude-code-powerline-statusline.git
cd claude-code-powerline-statusline
```

Copy the scripts into your Claude configuration directory:

```bash
mkdir -p ~/.claude
cp statusline-powerline.sh statusline-stop.sh ~/.claude/
chmod +x ~/.claude/statusline-powerline.sh ~/.claude/statusline-stop.sh
```

Merge the snippet below into `~/.claude/settings.json`. If the file already has
other settings, keep them and add only these two sections.

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

Restart Claude Code after changing `settings.json`. The statusline command is
read live, but the Stop hook is registered at startup.

## How It Works

```text
Claude Code -- statusline JSON via stdin --> statusline-powerline.sh --> output
                                               |
                                               v
                         ~/.claude/statusline-tokens-<session_id>.json
                                               ^
                                               |
Claude Code -- Stop hook at turn end ----> statusline-stop.sh
```

The first line uses Claude Code's live statusline JSON:

| Display | Source |
|---|---|
| Model | `.model.display_name` or `.model.id` |
| Effort | `.effort.level` |
| Context usage | `.context_window.*` |
| Total cost | `.cost.total_cost_usd` |
| Rate limits | `.rate_limits.five_hour.*` and `.rate_limits.seven_day.*` |

The second line uses the snapshot written by `statusline-stop.sh`. The hook reads
the main transcript plus sub-agent transcripts and accumulates cost weights for:

| Category | Meaning |
|---|---|
| Write | input tokens plus cache write tokens |
| Out | output tokens |
| Cache | cache read tokens |

The displayed total cost always comes from Claude Code's own
`.cost.total_cost_usd`. The hardcoded model prices are only used to estimate how
that total should be allocated across Write / Output / Cache.

## Model Pricing

Model pricing is intentionally hardcoded to keep the scripts dependency-free and
fully local. When Claude adds or renames models, update both scripts.

In `statusline-powerline.sh`, update the fallback pricing table:

```bash
case "$model_id" in
  *new-model*) P_IN=3; P_OUT=15; P_CR=0.3; P_W5=3.75; P_W1=6 ;;
esac
```

Values are USD per million tokens:

| Variable | Meaning |
|---|---|
| `P_IN` | input token price |
| `P_OUT` | output token price |
| `P_CR` | cache read token price |
| `P_W5` | 5-minute cache write token price |
| `P_W1` | 1-hour cache write token price |

In `statusline-stop.sh`, update the `pin($m)` function with the model's input
price in USD per million tokens:

```jq
elif ($x|test("new-model";"i")) then 3
```

That hook assumes Anthropic's current multiplier structure:

| Item | Multiplier |
|---|---|
| output | input price x 5 |
| cache read | input price x 0.1 |
| 5-minute cache write | input price x 1.25 |
| 1-hour cache write | input price x 2 |

If a future model uses different multipliers, update the formulas in
`statusline-stop.sh` as well.

Unknown models fall back to Opus-tier pricing for the split estimate. The total
cost remains the value reported by Claude Code.

## Manual Test

Run the main script with sample input:

```bash
printf '%s\n' '{"model":{"display_name":"claude-opus-4-8","id":"claude-opus-4-8"},"effort":{"level":"high"},"cost":{"total_cost_usd":34.5},"context_window":{"used_percentage":66,"context_window_size":1000000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":300,"cache_read_input_tokens":4000}},"rate_limits":{"five_hour":{"used_percentage":21},"seven_day":{"used_percentage":3}},"session_id":"sample-session"}' \
  | bash ./statusline-powerline.sh
```

Check script syntax:

```bash
bash -n ./statusline-powerline.sh
bash -n ./statusline-stop.sh
```

Run the full smoke test:

```bash
bash tests/smoke.sh
```

The repository also includes a GitHub Actions workflow that runs the smoke test
on Ubuntu and macOS.

## Customization

Edit `statusline-powerline.sh`:

| Setting | Where |
|---|---|
| Gap between left and right groups | `gap=$(printf '%*s' 24 '')` |
| Colors | `BG_*` variables |
| Segments | `L_TX`, `R_TX`, and `L2_TX` arrays |
| Separator glyph | `SEP=$'\xee\x82\xb0'` |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Powerline triangles show as boxes | Use a font with powerline glyphs. |
| The second line never updates | Restart Claude Code so the Stop hook is registered. |
| Context shows `--K` | Your Claude Code version may not provide `context_window` fields. |
| Statusline does not appear | Check the `statusLine.command` path and confirm `bash` and `jq` are available. |
| macOS cannot find `jq` | Install it with `brew install jq`; the scripts already add common Homebrew paths. |
| Windows path issues | Run from Git Bash and make sure `cygpath` is available. |

## License

MIT. See [LICENSE](LICENSE).
