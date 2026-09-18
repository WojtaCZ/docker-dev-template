<#
.SYNOPSIS
    Headless build + run for the baseline dev container on Windows.

.DESCRIPTION
    Builds the image (unless -NoBuild) and drops you into an interactive shell
    inside the container with /workspace bind-mounted to -Workspace (default:
    current directory), shared Claude auth, persistent package caches, and
    Docker Desktop's SSH agent forwarding.

.PARAMETER Workspace
    Host directory to mount at /workspace. Defaults to the current directory.

.PARAMETER NoBuild
    Skip `docker build` and just run the existing image.

.PARAMETER NoPull
    Skip `--pull` (don't refresh base image layers). Useful offline or when pinning.

.PARAMETER Rebuild
    Force `docker build --no-cache` for a clean rebuild.

.PARAMETER NoCacheVolumes
    Don't mount the persistent npm/uv/cargo cache volumes.

.PARAMETER SkipUpdate
    Skip `claude update` on container start (faster cold start, works offline).

.PARAMETER Doctor
    Run dev-doctor and exit instead of opening an interactive shell.

.EXAMPLE
    .\scripts\dev-up.ps1
    .\scripts\dev-up.ps1 -Workspace C:\code\my-project
    .\scripts\dev-up.ps1 -Rebuild
    .\scripts\dev-up.ps1 -Doctor
#>
[CmdletBinding()]
param(
    [string]$Workspace = (Get-Location).Path,
    [string]$ImageName = "dev-template-baseline",
    [string]$ContainerName = "dev-template",
    [switch]$NoBuild,
    [switch]$NoPull,
    [switch]$Rebuild,
    [switch]$NoCacheVolumes,
    [switch]$SkipUpdate,
    [switch]$Doctor
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
    "-v", "${claudeDir}:/host-claude-dir"
)

# Persistent package caches — without these every --rm run re-downloads
# npm/uv/cargo content from scratch.
if (-not $NoCacheVolumes) {
    $dockerArgs += @(
        "-v", "dev-cache-npm:/home/dev/.npm",
        "-v", "dev-cache-uv:/home/dev/.cache/uv",
        "-v", "dev-cache-cargo:/home/dev/.cargo",
        "-v", "dev-cache-pkg:/home/dev/.cache/pkg"
    )
}

if ($SkipUpdate) { $dockerArgs += @("-e", "DEV_SKIP_UPDATE=1") }
if ($env:GITHUB_TOKEN) { $dockerArgs += @("-e", "GITHUB_TOKEN=$($env:GITHUB_TOKEN)") }

# Docker Desktop on Windows exposes the host ssh-agent at this magic socket.
# Requires the Windows OpenSSH Authentication Agent service to be running.
$dockerArgs += @(
    "-v", "/run/host-services/ssh-auth.sock:/ssh-agent",
    "-e", "SSH_AUTH_SOCK=/ssh-agent",
    $ImageName
)

# Docker Desktop's Linux VM always presents bind mounts as uid 1000, so the
# HOST_UID remap that dev-up.sh performs is not needed on Windows.

if ($Doctor) { $dockerArgs += "dev-doctor" }

& docker @dockerArgs
