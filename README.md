# Claude Realtime Dashboard

A polished, info-dense statusline for [Claude Code](https://claude.com/claude-code) — turns the default one-liner into a real-time dashboard with per-turn token deltas, per-turn cost, threshold-colored progress bars, rate-limit countdowns, and a tier-coded effort indicator.

![preview](preview.png)
<!-- Replace preview.png with an actual screenshot of your statusline after install. -->

## What it shows

Five color-coded panels, left to right:

| Panel | Contents |
|---|---|
| **Model** | Model name (bold cyan) + effort tier — color reacts to operation cost: `LOW`/`MIN` dim cyan, `MEDIUM` cyan, `HIGH` yellow, `XHIGH`/`MAX` bold red |
| **Context** | This-turn token delta (`＋608`, bold red) · session size (`81.7k/1M`) · 10-cell bar + percentage (green < 50% · yellow < 80% · bold red ≥ 80%) |
| **Rate limits** | `5h` and `7d` Pro/Max subscription windows — bar + percentage (threshold-colored) + time-until-reset (e.g. `3h22m`, `4d18h`) in dim white |
| **Git** | `GIT:` (bold cyan) + branch name (green, or magenta when equal to `main`) · `WT:` + worktree name (same rule) |
| **Cost** | This-turn cost delta (`＋$0.14`, bold red) · session total (`$13.32`) |

Deltas always sit **left** of totals for consistent visual flow. The fullwidth `＋` glyph and bold red on deltas make per-turn cost impossible to miss.

## Why it's different

- **Honest token deltas.** The `＋Xk` excludes `cache_read_input_tokens` — it shows new work added this turn (your message + attachments + my output), not the re-shipped context that makes every turn look the same size as the conversation.
- **Per-turn cost alongside session total.** `＋$0.14 · $13.32` lets you see what *this specific request* cost while keeping the running tally visible.
- **Tier-coded effort.** Cranking up to `MAX` paints the indicator bold red — a friendly reminder you're spending more. Drop back to `MEDIUM` and it goes calm.
- **Rate-limit reset times.** Knowing "5h window at 19%, resets in 3h22m" is the difference between casually planning a session and being throttled mid-flow.
- **Threshold colors.** Bars and percentages turn yellow at 50% and bold red at 80% — visual warning before you hit a wall.
- **Box-drawing panels.** Each section is wrapped in `╭─⟨ … ⟩─╮` for a small floating-widget feel, with section-specific bracket colors.
- **`main` flag.** Branches and worktrees named `main` render in magenta; everything else is green. Easy to glance at and know whether you're on the trunk.

## Install (Windows · PowerShell)

1. **Copy** `statusline.ps1` into your Claude Code config directory:
   ```powershell
   Copy-Item .\statusline.ps1 $env:USERPROFILE\.claude\statusline.ps1
   ```

2. **Edit** `~/.claude/settings.json` (or merge into your existing config):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\YOUR_NAME\\.claude\\statusline.ps1\""
     }
   }
   ```
   Replace `YOUR_NAME` with your Windows username.

3. **Restart** Claude Code. The dashboard renders after each turn.

That's it.

## Requirements

- **Windows 10/11** with [Windows Terminal](https://aka.ms/terminal) (recommended) or any ANSI-capable host
- **PowerShell 5.1+** or PowerShell 7+ (both work)
- **Claude Code CLI** — terminal mode only; the statusline doesn't render inside the VS Code extension chat panel (a Claude Code limitation, not this script)
- A monospace font with box-drawing characters — Cascadia Mono / Cascadia Code (default in Windows Terminal) work out of the box

## Anatomy of a render

```
╭─⟨ Opus 4.7 · MEDIUM ⟩─╮  ╭─⟨ ＋608 · 81.7k/1M ▕█░░░░░░░░░▏ 8% ⟩─╮  ╭─⟨ 5h ▕░░░░░░░░░░▏ 3% 3h22m · 7d ▕█░░░░░░░░░▏ 9% 4d18h ⟩─╮  ╭─⟨ GIT:my-feature · WT:main ⟩─╮  ╭─⟨ ＋$0.14 · $13.32 ⟩─╮
```

## Configuration

### Model pricing
Rates are resolved per current model via `Get-ModelRates` in `statusline.ps1`. Supported out of the box (per 1M tokens, verified against the [Anthropic pricing page](https://platform.claude.com/docs/en/docs/about-claude/pricing)):

| Model | Input | 5m Cache Write | Cache Read | Output |
|---|---|---|---|---|
| Opus 4.7 / 4.6 / 4.5 | $5 | $6.25 | $0.50 | $25 |
| Sonnet 4.6 / 4.5 / 4 | $3 | $3.75 | $0.30 | $15 |

Unrecognized models fall back to the Opus 4.5+ rate. To add another model (e.g. Haiku 4.5 at $1 / $1.25 / $0.10 / $5, or legacy Opus 4 / 4.1 at $15 / $18.75 / $1.50 / $75), append a branch to `Get-ModelRates` before the fallback.

### Colors
ANSI SGR codes appear inline next to each `Wrap` call. Common edits:
- Panel bracket colors (search `Wrap '36' $brL` etc.)
- Threshold breakpoints (in the `Threshold` function — currently 50% / 80%)
- `main` branch flag color (search `if ($branch -eq 'main')`)

### Bar width
Bars are 10 cells. Search `Pct / 10.0` and `* 10` in `Make-Bar` to change density.

## Troubleshooting

- **I see raw `␛[36m…` text instead of colors.** Your terminal isn't processing ANSI. Use Windows Terminal, or enable virtual terminal in your PowerShell profile.
- **Line wraps onto a second row.** Your terminal is narrower than ~210 columns. Cheapest fixes: shrink bar width from 10 → 6 cells, drop the inner `─` from each frame, or drop the `GIT:`/`WT:` prefixes.
- **Time-until-reset shows nothing.** The harness payload may have changed field names. Add this near the top of `statusline.ps1` to dump and inspect:
  ```powershell
  $data.rate_limits | ConvertTo-Json -Depth 5 | Out-File C:\tmp\rl.json
  ```
- **Per-turn cost differs slightly from the session-total delta.** Local pricing math doesn't account for sub-agent or MCP server billing the harness may track separately. Within a cent for normal turns.

## Limitations

- Windows + PowerShell only by design (no Mac/Linux port planned)
- Pricing covers Opus 4.5+ and Sonnet families; other models fall back to Opus rates until you add them
- Doesn't render in VS Code's native Claude Code extension chat panel — terminal `claude` only
- No persistent state — sparklines / multi-session trends would need a state file

## License

MIT — see [LICENSE](LICENSE).
