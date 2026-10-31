# UI helpers: colored messages, prompts, picker.

$script:CtxAnsiCodes = @{
    Black = 30; DarkBlue = 34; DarkGreen = 32; DarkCyan = 36; DarkRed = 31; DarkMagenta = 35; DarkYellow = 33; Gray = 37
    DarkGray = 90; Blue = 94; Green = 92; Cyan = 96; Red = 91; Magenta = 95; Yellow = 93; White = 97
}
$script:CtxPalette = @('Cyan', 'Green', 'Magenta', 'Blue', 'Yellow', 'DarkCyan', 'DarkGreen', 'DarkMagenta', 'DarkYellow')
$script:CtxEsc = [char]27

function Get-CtxAnsi {
    param([string]$Color)
    if (-not $Color) { return '' }
    $code = $script:CtxAnsiCodes[$Color]
    if (-not $code) { return '' }
    "$($script:CtxEsc)[$($code)m"
}

function Get-CtxAnsiReset { "$($script:CtxEsc)[0m" }

function Remove-CtxAnsi {
    param([string]$Text)
    $Text -replace "$([char]27)\[[0-9;]*m", ''
}

function Get-CtxEnvColor {
    param($Entry)
    if ($Entry.color -and $script:CtxAnsiCodes.ContainsKey([string]$Entry.color)) { return [string]$Entry.color }
    if (Test-CtxProd $Entry) { return 'Red' }
    $sum = 0
    foreach ($ch in ([string]$Entry.name).ToCharArray()) { $sum += [int]$ch }
    $script:CtxPalette[$sum % $script:CtxPalette.Count]
}

function Write-CtxMsg {
    param(
        [Parameter(Position = 0)][ValidateSet('info', 'ok', 'warn', 'error', 'step', 'dim')][string]$Kind = 'info',
        [Parameter(Position = 1)][string]$Text
    )
    if ($script:Quiet -and $Kind -in 'info', 'ok', 'step', 'dim') { return }
    switch ($Kind) {
        'ok' { Write-Host '  ✓ ' -ForegroundColor Green -NoNewline; Write-Host $Text }
        'warn' { Write-Host '  ! ' -ForegroundColor Yellow -NoNewline; Write-Host $Text -ForegroundColor Yellow }
        'error' { Write-Host '  ✗ ' -ForegroundColor Red -NoNewline; Write-Host $Text -ForegroundColor Red }
        'step' { Write-Host '  › ' -ForegroundColor Cyan -NoNewline; Write-Host $Text }
        'dim' { Write-Host "    $Text" -ForegroundColor DarkGray }
        default { Write-Host "    $Text" }
    }
}

function Test-CtxInteractive {
    try {
        -not [Console]::IsInputRedirected -and [Environment]::UserInteractive -and $Host.Name -ne 'Default Host'
    } catch { $false }
}

function Read-CtxYesNo {
    param([Parameter(Mandatory)][string]$Question, [bool]$Default = $false)
    if (-not (Test-CtxInteractive)) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "  ? $Question $hint").Trim().ToLowerInvariant()
        if (-not $answer) { return $Default }
        if ($answer -in 'y', 'yes', 'j', 'ja') { return $true }
        if ($answer -in 'n', 'no', 'nein') { return $false }
    }
}

function Read-CtxText {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default, [switch]$Required)
    if (-not (Test-CtxInteractive)) {
        if ($Required -and -not $Default) { throw "Input required for '$Prompt' but the session is not interactive." }
        return $Default
    }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    while ($true) {
        $value = (Read-Host "  ? $Prompt$suffix").Trim()
        if (-not $value) { $value = $Default }
        if ($value -or -not $Required) { return $value }
    }
}

function Confirm-CtxTyped {
    param([Parameter(Mandatory)][string]$Expected, [Parameter(Mandatory)][string]$Message)
    if (-not (Test-CtxInteractive)) { throw "$Message Re-run with -Force in non-interactive sessions." }
    Write-Host "  ! $Message" -ForegroundColor Yellow
    $typed = Read-Host "  ? Type '$Expected' to continue"
    $typed.Trim() -ieq $Expected
}

function Write-CtxProdBanner {
    param($Entry)
    $line = " PRODUCTION · $($Entry.name) · $($Entry.tenantName) · $($Entry.upn) "
    Write-Host ''
    Write-Host $line -ForegroundColor White -BackgroundColor DarkRed
    Write-Host ''
}

function Format-CtxDuration {
    param([Nullable[timespan]]$Span)
    if ($null -eq $Span) { return '∞' }
    $s = [timespan]$Span
    if ($s.TotalSeconds -le 0) { return '0m' }
    if ($s.TotalHours -ge 1) { return '{0}h{1:00}m' -f [int][math]::Floor($s.TotalHours), $s.Minutes }
    '{0}m' -f [int][math]::Ceiling($s.TotalMinutes)
}

function Format-CtxAgo {
    param($When)
    $d = ConvertTo-CtxDate $When
    if (-not $d) { return 'never' }
    $span = [datetime]::UtcNow - $d
    if ($span.TotalMinutes -lt 1) { return 'just now' }
    if ($span.TotalHours -lt 1) { return '{0}m ago' -f [int]$span.TotalMinutes }
    if ($span.TotalDays -lt 1) { return '{0}h ago' -f [int][math]::Floor($span.TotalHours) }
    if ($span.TotalDays -lt 60) { return '{0}d ago' -f [int][math]::Floor($span.TotalDays) }
    $d.ToLocalTime().ToString('yyyy-MM-dd')
}

function Format-CtxCell {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) { return $Text.Substring(0, [math]::Max(0, $Width - 1)) + '…' }
    $Text.PadRight($Width)
}

function New-CtxMenuFrame {
    param(
        [Parameter(Mandatory)][string[]]$Rows,
        [int]$Selected,
        [int]$Start,
        [ValidateRange(1, [int]::MaxValue)][int]$Width,
        [ValidateRange(3, [int]::MaxValue)][int]$Height,
        [string[]]$Colors,
        [string]$Footer
    )
    $count = [math]::Min($Rows.Count, $Height - 2)
    $Start = [math]::Max(0, [math]::Min($Start, $Rows.Count - $count))
    if ($Selected -lt $Start) { $Start = $Selected }
    elseif ($Selected -ge $Start + $count) { $Start = $Selected - $count + 1 }

    $esc = $script:CtxEsc
    $reset = Get-CtxAnsiReset
    $sb = [Text.StringBuilder]::new()
    for ($i = $Start; $i -lt $Start + $count; $i++) {
        $num = if ($i -lt 9) { "$($i + 1)" } else { ' ' }
        $text = if ($Width -gt 2) { Format-CtxCell (" $num  " + ($Rows[$i] -replace '[\r\n\t]', ' ')) ($Width - 2) } else { '' }
        $bullet = if ($Colors -and $Colors[$i]) { (Get-CtxAnsi $Colors[$i]) + '●' + $reset } else { '●' }
        if ($Width -eq 1) { $bullet = ''; $text = '' }
        if ($i -eq $Selected) {
            [void]$sb.Append("$esc[2K`r$esc[1;96m›$reset$bullet$esc[7m$text$reset`n")
        } else {
            [void]$sb.Append("$esc[2K`r $bullet$text`n")
        }
    }
    $footerText = Format-CtxCell ("  " + ($Footer -replace '[\r\n\t]', ' ')) $Width
    # Leave the cursor on the footer: its newline would scroll a full-height menu.
    [void]$sb.Append("$esc[2K`r$esc[90m$footerText$reset$esc[J")
    @{ Text = $sb.ToString(); Start = $Start; Count = $count }
}

function Show-CtxMenu {
    <#
    Arrow-key menu. Returns @{ Index = n; Key = 'enter' | <extra key char> } or $null when cancelled.
    Rows are plain text; $Colors (optional) colors the bullet of each row.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Rows,
        [string]$Title,
        [string[]]$Colors,
        [int]$Default = 0,
        [string]$Footer = '↑/↓ move · Enter select · 1-9 jump · Esc cancel',
        [char[]]$ExtraKeys = @()
    )
    if (-not (Test-CtxInteractive)) { throw 'No interactive console available for the picker. Pass a name instead.' }
    if ($Rows.Count -eq 0) { return $null }
    $esc = $script:CtxEsc
    $sel = [math]::Max(0, [math]::Min($Default, $Rows.Count - 1))
    $cursorWasVisible = try { [Console]::CursorVisible } catch { $true }
    $start = 0
    $previousCount = 0
    try {
        try { [Console]::CursorVisible = $false } catch { Write-Debug "ctx: cannot hide the cursor: $_" }
        while ($true) {
            try {
                $width = [math]::Max(1, [Console]::WindowWidth - 1)
                $height = [math]::Max(3, [Console]::WindowHeight)
            } catch {
                Write-Debug "ctx: cannot read the console size: $_"
                $width = 119
                $height = 25
            }
            if ($previousCount -eq 0 -and $Title) {
                Write-Host (Format-CtxCell ($Title -replace '[\r\n\t]', ' ') $width) -ForegroundColor Cyan
            }
            $frame = New-CtxMenuFrame -Rows $Rows -Selected $sel -Start $start -Width $width -Height $height -Colors $Colors -Footer $Footer
            if ($previousCount -gt 0) {
                $rewind = [math]::Min($previousCount, $height - 1)
                [Console]::Write("$esc[$($rewind)A")
            }
            [Console]::Write($frame.Text)
            $start = $frame.Start
            $previousCount = $frame.Count

            $key = [Console]::ReadKey($true)
            $ch = [char]::ToLowerInvariant($key.KeyChar)
            if ($key.Key -eq [ConsoleKey]::UpArrow -or $ch -eq 'k') { $sel = ($sel - 1 + $Rows.Count) % $Rows.Count }
            elseif ($key.Key -eq [ConsoleKey]::DownArrow -or $ch -eq 'j') { $sel = ($sel + 1) % $Rows.Count }
            elseif ($key.Key -eq [ConsoleKey]::Home) { $sel = 0 }
            elseif ($key.Key -eq [ConsoleKey]::End) { $sel = $Rows.Count - 1 }
            elseif ($key.Key -eq [ConsoleKey]::Enter) { return @{ Index = $sel; Key = 'enter' } }
            elseif ($key.Key -eq [ConsoleKey]::Escape -or $ch -eq 'q') { return $null }
            elseif ($ch -ge '1' -and $ch -le '9') {
                $idx = [int]::Parse([string]$ch) - 1
                if ($idx -lt $Rows.Count) { return @{ Index = $idx; Key = 'enter' } }
            }
            elseif ($ExtraKeys -contains $ch) { return @{ Index = $sel; Key = [string]$ch } }
        }
    } finally {
        if ($previousCount -gt 0) { [Console]::WriteLine() }
        try { [Console]::CursorVisible = $cursorWasVisible } catch { Write-Debug "ctx: cannot restore the cursor: $_" }
    }
}

function Get-CtxEditorCommand {
    <# Editor for 'ctx config -Edit': command first, then its arguments ($env:EDITOR may be 'code --wait'). #>
    $spec = $env:EDITOR
    if (-not $spec) { return $(if (Get-Command code -ErrorAction SilentlyContinue) { 'code' } else { 'notepad' }) }
    if (Get-Command $spec -ErrorAction SilentlyContinue) { return $spec }
    @([regex]::Matches($spec, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })
}

function Test-CtxModuleSignature {
    <#
    Authenticode state of the module files for 'ctx doctor'. Once any file is signed (or carries a signature block),
    every file must still verify: text appended after a signature turns it into "not signed", not "hash mismatch".
    #>
    param([Parameter(Mandatory)][string]$ModuleBase)
    $checks = foreach ($name in 'Ctx.psm1', 'Ctx.psd1', 'Ctx.Format.ps1xml') {
        $file = Join-Path $ModuleBase $name
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $sig = Get-AuthenticodeSignature -LiteralPath $file
        [pscustomobject]@{
            Name    = $name
            Status  = [string]$sig.Status
            Signer  = $sig.SignerCertificate
            Message = $sig.StatusMessage
            # Only a real signature block counts (own line); this very code mentions the marker inside a string.
            Block   = [IO.File]::ReadAllText($file) -match '(?m)^# SIG # Begin signature block\r?$'
        }
    }
    $checks = @($checks)
    $signed = @($checks | Where-Object Signer)
    $broken = @($checks | Where-Object { $_.Status -eq 'HashMismatch' -or ($_.Status -eq 'NotSigned' -and ($_.Block -or $signed.Count)) })
    if ($broken.Count) {
        return [pscustomobject]@{ Status = 'fail'; Detail = "$(($broken | ForEach-Object Name) -join ', ') changed after the module was signed - reinstall it with Install.ps1" }
    }
    if (-not $signed.Count) {
        $hint = if (Get-CtxOneDriveRoot $ModuleBase) { ' - code synced via OneDrive runs in every terminal; sign it with Install.ps1 -SigningCertificate' } else { '' }
        return [pscustomobject]@{ Status = 'info'; Detail = "not signed$hint" }
    }
    $untrusted = @($signed | Where-Object Status -NE 'Valid')
    if ($untrusted.Count) {
        return [pscustomobject]@{ Status = 'warn'; Detail = "$($untrusted[0].Status): $($untrusted[0].Message)" }
    }
    [pscustomobject]@{ Status = 'ok'; Detail = "signed by $($signed[0].Signer.Subject)" }
}
