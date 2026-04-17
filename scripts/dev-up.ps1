<#
.SYNOPSIS
    Headless build + run for the baseline dev container on Windows.

.DESCRIPTION
    Builds the image (unless -NoBuild) and drops you into an interactive shell
    inside the container with /workspace bind-mounted to -Workspace (default:
    current directory), shared Claude auth, and Docker Desktop's SSH agent
    forwarding.

.PARAMETER Workspace
    Host directory to mount at /workspace. Defaults to the current directory.

.PARAMETER NoBuild
    Skip `docker build` and just run the existing image.

.PARAMETER NoPull
    Skip `--pull` (don't refresh base image layers). Useful offline or when pinning.

.PARAMETER Rebuild
    Force `docker build --no-cache` for a clean rebuild.

.EXAMPLE
    .\scripts\dev-up.ps1
    .\scripts\dev-up.ps1 -Workspace C:\code\my-project
    .\scripts\dev-up.ps1 -Rebuild
#>
[CmdletBinding()]
param(
    [string]$Workspace = (Get-Location).Path,
    [string]$ImageName = "dev-template-baseline",
    [string]$ContainerName = "dev-template",
    [switch]$NoBuild,
    [switch]$NoPull,
    [switch]$Rebuild
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $NoBuild) {
    $buildFlags = @()
    if (-not $NoPull) { $buildFlags += "--pull" }
    if ($Rebuild)     { $buildFlags += "--no-cache" }
    docker build @buildFlags -t $ImageName $repoRoot
    if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
}

$claudeJson = Join-Path $env:USERPROFILE ".claude.json"
$claudeDir  = Join-Path $env:USERPROFILE ".claude"

if (-not (Test-Path $claudeJson)) {
    Write-Warning "$claudeJson not found. Run 'claude' on the host at least once so auth exists."
}
if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir | Out-Null
}

$dockerArgs = @(
    "run", "--rm", "-it",
    "--name", $ContainerName,
    "--init",
    "-v", "${Workspace}:/workspace",
    "-v", "${claudeJson}:/host-claude-auth.json",
    "-v", "${claudeDir}:/host-claude-dir",
    # Docker Desktop on Windows exposes the host ssh-agent at this magic socket.
    # Requires the Windows OpenSSH Authentication Agent service to be running.
    "-v", "/run/host-services/ssh-auth.sock:/ssh-agent",
    "-e", "SSH_AUTH_SOCK=/ssh-agent",
    $ImageName
)

& docker @dockerArgs
