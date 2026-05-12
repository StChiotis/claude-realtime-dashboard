$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# Inner separator (middle dot U+00B7) — built at runtime so the script source
# stays ASCII-safe and the codepoint can't get mangled by file-encoding drift.
$mdot = [char]0x00B7
$sep  = " $mdot "

# Dashboard panel chars and progress-bar elements (built from codepoints for
# the same encoding-safety reason as the middle dot above).
# Panel frames use rounded box-drawing corners + angle brackets to suggest a
# small floating panel header: ╭─⟨ content ⟩─╮
$cTL    = [string][char]0x256D  # ╭  (rounded down+right)
$cTR    = [string][char]0x256E  # ╮  (rounded down+left)
$hLin   = [string][char]0x2500  # ─  (light horizontal)
$angL   = [string][char]0x27E8  # ⟨  (math left angle bracket)
$angR   = [string][char]0x27E9  # ⟩  (math right angle bracket)
$brL    = "${cTL}${hLin}${angL}"  # ╭─⟨
$brR    = "${angR}${hLin}${cTR}"  # ⟩─╮
$bFull  = [string][char]0x2588  # █
$bEmpty = [string][char]0x2591  # ░
$bLEdg  = [string][char]0x2595  # ▕
$bREdg  = [string][char]0x258F  # ▏
$bigPlus = [string][char]0xFF0B  # ＋  (fullwidth plus — visually larger than '+')

# ANSI SGR helpers. Output supports ANSI on Windows Terminal / modern PS hosts.
# If your terminal renders raw `ESC[…m` text, comment out the Wrap calls below.
$esc = [char]27
function Wrap {
    param([string]$Code, [string]$Text)
    return "$esc[${Code}m${Text}$esc[0m"
}
# Threshold color for a 0-100 percentage: green <50, yellow <80, bold red >=80.
function Threshold {
    param([double]$Pct)
    if ($Pct -ge 80) { return '1;31' }
    if ($Pct -ge 50) { return '33' }
    return '32'
}

# Format time-until-reset as compact "Xd Yh", "Xh Ym", or "Xm". Accepts either
# a Unix timestamp (seconds since epoch — what Claude Code currently sends) or
# an ISO 8601 string. Empty if missing or the reset is in the past.
function Format-Remaining {
    param($ResetsAt)
    if ($null -eq $ResetsAt) { return '' }
    try {
        $resetTime = $null
        if ($ResetsAt -is [long] -or $ResetsAt -is [int] -or $ResetsAt -is [double]) {
            $resetTime = [DateTimeOffset]::FromUnixTimeSeconds([long]$ResetsAt)
        } else {
            $s = [string]$ResetsAt
            # Numeric string? treat as Unix timestamp.
            $n = 0L
            if ([long]::TryParse($s, [ref]$n)) {
                $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($n)
            } else {
                $resetTime = [DateTimeOffset]::Parse($s)
            }
        }
        $delta = $resetTime - [DateTimeOffset]::Now
        if ($delta.TotalSeconds -le 0) { return '0m' }
        if ($delta.TotalDays -ge 1) {
            $d = [int][math]::Floor($delta.TotalDays)
            $h = $delta.Hours
            if ($h -gt 0) { return "${d}d${h}h" } else { return "${d}d" }
        }
        if ($delta.TotalHours -ge 1) {
            $h = [int][math]::Floor($delta.TotalHours)
            $m = $delta.Minutes
            if ($m -gt 0) { return "${h}h${m}m" } else { return "${h}h" }
        }
        $m = [int][math]::Floor($delta.TotalMinutes)
        if ($m -lt 1) { return '<1m' }
        return "${m}m"
    } catch { return '' }
}

function Make-Bar {
    param([double]$Pct)
    if ($null -eq $Pct) { $Pct = 0 }
    if ($Pct -lt 0)   { $Pct = 0 }
    if ($Pct -gt 100) { $Pct = 100 }
    $f = [int][math]::Round($Pct / 10.0)
    if ($f -lt 0)  { $f = 0 }
    if ($f -gt 10) { $f = 10 }
    $e = 10 - $f
    return $bLEdg + ($bFull * $f) + ($bEmpty * $e) + $bREdg
}

# Per-million-token rates by model, returned as @{ in; cc; cr; out }.
# Verified against the Anthropic pricing page on 2026-05-12. Note: Opus 4.5+
# uses the NEW lower tier ($5/$25 input/output), not the legacy Opus 4/4.1
# rate of $15/$75. To add a model, append another branch with its quartet.
function Get-ModelRates {
    param([string]$ModelId, [string]$ModelDisplay)
    $tag = ($ModelId + ' ' + $ModelDisplay).ToLower()
    # Opus 4.5 / 4.6 / 4.7 — new lower tier
    if ($tag -match 'opus[\s._-]*4[\s._-]*[567]' -or $tag -match 'opus-4-[567]') {
        return @{ in = 5.0;  cc = 6.25;  cr = 0.50; out = 25.0 }
    }
    # Sonnet (3.7 / 4 / 4.5 / 4.6 — same rate across this family)
    if ($tag -match 'sonnet') {
        return @{ in = 3.0;  cc = 3.75;  cr = 0.30; out = 15.0 }
    }
    # Conservative fallback: assume new-tier Opus pricing. If you use Haiku
    # or legacy Opus 4/4.1, add a branch above this line.
    return @{ in = 5.0; cc = 6.25; cr = 0.50; out = 25.0 }
}
$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { return }

# --- Model ---
$model = $data.model.display_name
if (-not $model) { $model = $data.model.id }

# --- Effort level (live from payload; fall back to user settings) ---
$effort = $null
if ($data.effort -and $data.effort.level) { $effort = [string]$data.effort.level }
elseif ($data.effort_level)               { $effort = [string]$data.effort_level }
else {
    $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path $settingsPath) {
        try {
            $userSettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($userSettings.effortLevel) { $effort = [string]$userSettings.effortLevel }
        } catch {}
    }
}

# --- CWD ---
$cwd = $data.workspace.current_dir
if (-not $cwd) { $cwd = $data.cwd }

# --- Session cost (USD) ---
$cost = $null
if ($data.cost -and ($null -ne $data.cost.total_cost_usd)) {
    $cost = [math]::Round([double]$data.cost.total_cost_usd, 2)
}

# --- Git branch + worktree at cwd ---
$branch = ''
$worktree = ''
if ($cwd -and (Test-Path (Join-Path $cwd '.git'))) {
    try {
        $b = & git -C $cwd branch --show-current 2>$null
        if ($b) { $branch = $b.Trim() }
        # Always state which worktree we're in: linked → leaf name, main checkout → 'main'
        $absGitDir = & git -C $cwd rev-parse --absolute-git-dir 2>$null
        if ($absGitDir -and ($absGitDir -match '[\\/]worktrees[\\/]([^\\/]+)')) {
            $worktree = $matches[1]
        } else {
            $worktree = 'main'
        }
    } catch {}
}

# --- Context window (use harness-provided fields; fall back to transcript) ---
$ctx = ''
$perMsgLabel = ''
$over = $false

# Per-turn token totals (used for both the +Xk label and the per-turn cost).
# Initialized here so they're defined even when no context_window is present.
$turnIn = 0; $turnCC = 0; $turnCR = 0; $turnOut = 0

$cw = $data.context_window
if ($cw) {
    $size = 0
    if ($null -ne $cw.context_window_size) { $size = [int]$cw.context_window_size }
    if ($size -le 0) { $size = 200000 }

    $used = 0
    if (($null -ne $cw.total_input_tokens) -or ($null -ne $cw.total_output_tokens)) {
        $used = [int]$cw.total_input_tokens + [int]$cw.total_output_tokens
    } elseif ($cw.current_usage) {
        $cu = $cw.current_usage
        $used = [int]$cu.input_tokens + [int]$cu.cache_read_input_tokens + [int]$cu.cache_creation_input_tokens + [int]$cu.output_tokens
    }

    # Per-message tokens = NEW work added this turn (user message + attachments
    # + any tool results read + my output). Excludes cache_read because that's
    # the already-existing conversation being re-shipped on every API call —
    # it doesn't scale with what the user actually sent.
    #
    # Sums across all API calls since the last REAL user message, so tool-heavy
    # turns and high-effort turns (multiple internal round-trips) are captured
    # in full. Each API call is written as multiple JSONL lines (one per
    # content block); dedupe by message.id so each call counts once.
    $perMsg = 0
    $transcriptForTurn = $data.transcript_path
    if ($transcriptForTurn -and (Test-Path $transcriptForTurn)) {
        try {
            $lines = Get-Content $transcriptForTurn
            $seenMsgIds = @{}
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                try { $obj = $lines[$i] | ConvertFrom-Json } catch { continue }
                if ($obj.type -eq 'user') {
                    $kind = $null
                    if ($obj.message -and $obj.message.content) {
                        $c = $obj.message.content
                        if ($c -is [System.Array] -and $c.Count -gt 0) { $kind = $c[0].type }
                        elseif ($c.type) { $kind = $c.type }
                    }
                    if ($kind -ne 'tool_result') { break }   # real user turn — stop
                    continue                                  # tool_result — skip past
                }
                if ($obj.type -eq 'assistant' -and $obj.message -and $obj.message.usage -and $obj.message.id) {
                    if (-not $seenMsgIds.ContainsKey($obj.message.id)) {
                        $seenMsgIds[$obj.message.id] = $true
                        $u = $obj.message.usage
                        $turnIn  += [int]$u.input_tokens
                        $turnCC  += [int]$u.cache_creation_input_tokens
                        $turnCR  += [int]$u.cache_read_input_tokens
                        $turnOut += [int]$u.output_tokens
                    }
                }
            }
            # "+Xk" excludes cache_read (re-shipped existing context).
            $perMsg = $turnIn + $turnCC + $turnOut
        } catch {}
    }
    if ($perMsg -le 0 -and $cw.current_usage) {
        $cu2 = $cw.current_usage
        $turnIn  = [int]$cu2.input_tokens
        $turnCC  = [int]$cu2.cache_creation_input_tokens
        $turnCR  = [int]$cu2.cache_read_input_tokens
        $turnOut = [int]$cu2.output_tokens
        $perMsg = $turnIn + $turnCC + $turnOut
    }
    if ($perMsg -gt 0) {
        if ($perMsg -ge 1000) {
            $perMsgLabel = $bigPlus + [string]([math]::Round($perMsg / 1000.0, 1)) + 'k'
        } else {
            $perMsgLabel = $bigPlus + [string]$perMsg
        }
    }

    $pct = $null
    if ($null -ne $cw.used_percentage) {
        $pct = [math]::Round([double]$cw.used_percentage, 1)
    } elseif ($used -gt 0) {
        $pct = [math]::Round(($used / [double]$size) * 100, 1)
    }

    if ($size -ge 1000000) {
        $winLabel = [string]([math]::Round($size / 1000000.0, 1)) + 'M'
    } else {
        $winLabel = [string]([math]::Round($size / 1000.0, 0)) + 'k'
    }

    if ($used -gt 0 -and $null -ne $pct) {
        $kUsed = [math]::Round($used / 1000.0, 1)
        $tc = Threshold $pct
        $cBar = Wrap $tc (Make-Bar $pct)
        $cPct = Wrap $tc "${pct}%"
        $ctx = "${kUsed}k/${winLabel} ${cBar} ${cPct}"
    } elseif ($null -ne $pct) {
        $tc = Threshold $pct
        $cBar = Wrap $tc (Make-Bar $pct)
        $cPct = Wrap $tc "${pct}%"
        $ctx = "${cBar} ${cPct} / ${winLabel}"
    }

    if ($null -ne $pct -and $pct -ge 80) { $over = $true }
}

# Fallback: pre-API-call render (no context_window yet). Parse transcript.
if (-not $ctx) {
    $transcript = $data.transcript_path
    if ($transcript -and (Test-Path $transcript)) {
        try {
            $lastUsage = $null
            foreach ($line in (Get-Content $transcript -Tail 80)) {
                try { $obj = $line | ConvertFrom-Json } catch { continue }
                if ($obj.message.usage) { $lastUsage = $obj.message.usage }
            }
            if ($lastUsage) {
                $inp   = [int]($lastUsage.input_tokens)
                $cread = [int]($lastUsage.cache_read_input_tokens)
                $ccre  = [int]($lastUsage.cache_creation_input_tokens)
                $total = $inp + $cread + $ccre
                $kTotal = [math]::Round($total / 1000.0, 1)
                $ctx = "${kTotal}k (window unknown)"
            }
        } catch {}
    }
}

# Brand-new session (no API call yet, no transcript usage): show explicit zeros
# as a visible baseline rather than collapsing the fields. Window default 1M
# matches Opus 4.7; the first API call will replace it with the real size.
if (-not $ctx)         { $ctx = '0k/1M ' + (Make-Bar 0) + ' 0%' }
if (-not $perMsgLabel) { $perMsgLabel = $bigPlus + '0' }
if ($null -eq $cost)   { $cost = 0 }

# --- Per-turn cost (USD) ---
# Rates resolved per current model via Get-ModelRates (defined above), so the
# delta tracks reality across model switches.
$rates = Get-ModelRates $data.model.id $data.model.display_name
$turnCost = ($turnIn * $rates.in + $turnCC * $rates.cc + $turnCR * $rates.cr + $turnOut * $rates.out) / 1000000.0

# --- Subscription rate limits (Pro/Max only, present after first API response) ---
$limits = ''
if ($data.rate_limits) {
    $rl = @()
    if ($data.rate_limits.five_hour -and ($null -ne $data.rate_limits.five_hour.used_percentage)) {
        $p5 = [math]::Round([double]$data.rate_limits.five_hour.used_percentage, 0)
        $tc5 = Threshold $p5
        $r5 = Format-Remaining $data.rate_limits.five_hour.resets_at
        $r5disp = if ($r5) { ' ' + (Wrap '2;37' $r5) } else { '' }
        $rl += '5h ' + (Wrap $tc5 (Make-Bar $p5)) + ' ' + (Wrap $tc5 "${p5}%") + $r5disp
    }
    if ($data.rate_limits.seven_day -and ($null -ne $data.rate_limits.seven_day.used_percentage)) {
        $p7 = [math]::Round([double]$data.rate_limits.seven_day.used_percentage, 0)
        $tc7 = Threshold $p7
        $r7 = Format-Remaining $data.rate_limits.seven_day.resets_at
        $r7disp = if ($r7) { ' ' + (Wrap '2;37' $r7) } else { '' }
        $rl += '7d ' + (Wrap $tc7 (Make-Bar $p7)) + ' ' + (Wrap $tc7 "${p7}%") + $r7disp
    }
    if ($rl.Count -gt 0) { $limits = ($rl -join $sep) }
}

# --- Build status line (dashboard panels) ---
# Each metric panel is bracketed by ┤ ├ in its own color so sections read as
# distinct widgets. Inside-panel thresholds (bars + percentages) are colored
# independently by the Threshold helper.
$parts = @()
if ($model) {
    $mc = Wrap '1;36' $model                                  # bold cyan
    if ($effort) {
        # Tier-color the effort: dim cyan (low) -> cyan (med) -> yellow (high)
        # -> bold red (xhigh/max). Lets the indicator function as an intensity
        # warning light rather than a static label.
        $eLow = $effort.ToLower()
        $eCol = '2;36'
        if     ($eLow -in @('min','low'))            { $eCol = '2;36' }
        elseif ($eLow -in @('medium','med'))         { $eCol = '36'   }
        elseif ($eLow -eq 'high')                    { $eCol = '33'   }
        elseif ($eLow -in @('xhigh','max','extreme')){ $eCol = '1;31' }
        $modelStr = "${mc}${sep}" + (Wrap $eCol $effort.ToUpper())
    } else {
        $modelStr = $mc
    }
    $parts += (Wrap '36' $brL) + " $modelStr " + (Wrap '36' $brR)
}
if ($ctx) {
    $pmCol = if ($perMsgLabel) { Wrap '1;31' $perMsgLabel } else { '' }   # bold red delta
    $ctxInner = if ($perMsgLabel) { "${pmCol}${sep}${ctx}" } else { $ctx }
    if ($over) { $ctxInner = "$ctxInner !" }
    $parts += (Wrap '34' $brL) + " $ctxInner " + (Wrap '34' $brR)   # blue panel
}
if ($limits) {
    $parts += (Wrap '35' $brL) + " $limits " + (Wrap '35' $brR)     # magenta panel
}
if ($branch) {
    # Prefixes ("git:" / "wt:") are bright white. The value is magenta when it
    # equals "main" (visual flag for being on/in main), green otherwise.
    $brCol = if ($branch -eq 'main') { '35' } else { '32' }
    $gitDisplay = (Wrap '1;36' 'GIT:') + (Wrap $brCol $branch)
    if ($worktree) {
        $wtCol = if ($worktree -eq 'main') { '35' } else { '32' }
        $gitDisplay = "${gitDisplay}${sep}" + (Wrap '1;36' 'WT:') + (Wrap $wtCol $worktree)
    }
    $parts += (Wrap '32' $brL) + " $gitDisplay " + (Wrap '32' $brR)
}
$delta   = Wrap '1;31' ($bigPlus + '$' + ('{0:N2}' -f $turnCost))    # bold red delta
$tot     = '$' + ('{0:N2}' -f $cost)                                  # plain session total
$costStr = "${delta}${sep}${tot}"
$parts += (Wrap '33' $brL) + " $costStr " + (Wrap '33' $brR)         # yellow panel

Write-Output ($parts -join '  ')
