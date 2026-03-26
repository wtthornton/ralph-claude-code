# ralph.ps1 - Windows PowerShell wrapper for Ralph (Issue #156)
# Detects WSL or Git Bash and delegates ralph_loop.sh accordingly.
# Usage: .\ralph.ps1 --live, .\ralph.ps1 --version, etc.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RalphArgs
)

$ErrorActionPreference = "Stop"

function Convert-ToUnixPath {
    param([string]$WinPath)
    # Convert Windows path to Unix path for bash
    $drive = $WinPath.Substring(0, 1).ToLower()
    $rest = $WinPath.Substring(2) -replace '\\', '/'
    return "/mnt/$drive$rest"
}

function Find-BashExecutable {
    # 1. Check for WSL
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        # Verify WSL is functional
        try {
            $result = & wsl.exe --status 2>&1
            if ($LASTEXITCODE -eq 0 -or $result -match "Default Distribution") {
                return @{ Type = "wsl"; Path = "wsl.exe" }
            }
        } catch {
            # WSL not functional, fall through
        }
    }

    # 2. Check for Git Bash
    $gitBashPaths = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "$env:ProgramFiles(x86)\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($p in $gitBashPaths) {
        if (Test-Path $p) {
            return @{ Type = "gitbash"; Path = $p }
        }
    }

    # 3. Check for bash.exe on PATH (e.g., MSYS2, Cygwin)
    $bash = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($bash) {
        return @{ Type = "bash"; Path = $bash.Source }
    }

    return $null
}

# Find the ralph_loop.sh script
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ralphScript = Join-Path $scriptDir "ralph_loop.sh"

if (-not (Test-Path $ralphScript)) {
    # Check global installation
    $globalScript = Join-Path $env:USERPROFILE ".ralph\ralph_loop.sh"
    if (Test-Path $globalScript) {
        $ralphScript = $globalScript
    } else {
        Write-Error "Cannot find ralph_loop.sh in '$scriptDir' or '$env:USERPROFILE\.ralph\'"
        exit 1
    }
}

# Find a bash environment
$bashInfo = Find-BashExecutable

if (-not $bashInfo) {
    Write-Error @"
No bash environment found. Ralph requires one of:
  - WSL (Windows Subsystem for Linux): wsl --install
  - Git Bash: https://git-scm.com/download/win
  - MSYS2: https://www.msys2.org/
"@
    exit 1
}

# Build the argument string
$argString = ""
if ($RalphArgs) {
    $argString = ($RalphArgs | ForEach-Object {
        if ($_ -match '\s') { "'$_'" } else { $_ }
    }) -join " "
}

# Execute based on bash type
switch ($bashInfo.Type) {
    "wsl" {
        $unixScript = Convert-ToUnixPath $ralphScript
        & wsl.exe bash -c "$unixScript $argString"
    }
    "gitbash" {
        # Git Bash uses /c/path/to/file style
        $gitBashPath = $ralphScript -replace '\\', '/'
        $gitBashPath = $gitBashPath -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() }
        & $bashInfo.Path -c "$gitBashPath $argString"
    }
    "bash" {
        & $bashInfo.Path -c "$ralphScript $argString"
    }
}

exit $LASTEXITCODE
