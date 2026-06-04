#requires -Version 5.1
# ──────────────────────────────────────────────────────────────────────────────
# bootstrap-pulumi.ps1 — Pulumi+Go equivalent of bootstrap.ps1.
#
# Same end state as the Terraform path: VM + RKE2 + ArgoCD + root Application
# + every workload reconciled by ArgoCD. Only the IaC step differs:
# `pulumi up` instead of `terraform apply`.
#
# DO NOT run alongside bootstrap.ps1 — both paths target the same VirtualBox
# VM name (rke2-server-1) and host-only IP (192.168.56.10). Pick one per
# session.
#
# Pipeline:
#   1. Pre-flight: vagrant, pulumi, go, kubectl, helm on PATH
#   2. cd pulumi && pulumi up --yes --stack dev
#   3. Wait for vault-0 pod = Running
#   4. Run init-vault.ps1
#   5. (Optional) Wait for every Argo Application Healthy
#   6. Print summary
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap-pulumi.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap-pulumi.ps1 -WaitForHealthy
#   powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap-pulumi.ps1 -SkipPulumi
#
# Exit codes match bootstrap.ps1 (1..5). Code 2 means `pulumi up` failed
# (vs `terraform apply` failed in the sibling script).
# ──────────────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    [switch]$SkipPulumi,            # Skip pulumi up (cluster already exists)
    [switch]$WaitForHealthy,        # Wait for all Argo apps Healthy (slow)
    [int]   $VaultWaitMinutes = 20,
    [int]   $AppsWaitMinutes  = 25,
    [string]$Stack = 'dev'
)

$ErrorActionPreference = 'Stop'
$RepoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
$Kubeconfig = Join-Path $RepoRoot 'kubeconfig'
$PulumiDir  = Join-Path $RepoRoot 'pulumi'

function Log {
    param([string]$Msg, [string]$Color = 'Cyan')
    Write-Host "[bootstrap-pulumi] $Msg" -ForegroundColor $Color
}
function Fail {
    param([string]$Msg, [int]$ExitCode)
    Write-Host "[bootstrap-pulumi] FAILED: $Msg" -ForegroundColor Red
    exit $ExitCode
}

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
Log 'Pre-flight: checking tools on PATH'
$missing = @()
foreach ($t in 'vagrant','pulumi','go','kubectl','helm') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
}
if ($missing.Count -gt 0) {
    Fail "missing tool(s) on PATH: $($missing -join ', '). See README + docs/pulumi-mirror.md." 1
}
Log 'Pre-flight OK' 'Green'

# ── 2. Stack passphrase ───────────────────────────────────────────────────────
# Pulumi encrypts secrets in state with PULUMI_CONFIG_PASSPHRASE.
# For the lab any non-empty string is fine; do NOT use a real production secret.
if (-not $env:PULUMI_CONFIG_PASSPHRASE) {
    Log 'PULUMI_CONFIG_PASSPHRASE not set — using lab default. Override before any real workload.' 'Yellow'
    $env:PULUMI_CONFIG_PASSPHRASE = 'lab-passphrase-change-me'
}

# ── 3. Pulumi up ──────────────────────────────────────────────────────────────
if (-not $SkipPulumi) {
    Log "pulumi up (this builds the VM + installs RKE2 + ArgoCD; stack=$Stack)"
    Push-Location $PulumiDir
    try {
        & pulumi login --local
        if ($LASTEXITCODE -ne 0) { Fail 'pulumi login --local failed' 2 }

        # Stack init is idempotent (errors if exists; ignored).
        & pulumi stack select $Stack 2>$null
        if ($LASTEXITCODE -ne 0) {
            & pulumi stack init $Stack
            if ($LASTEXITCODE -ne 0) { Fail "pulumi stack init $Stack failed" 2 }
        }

        & go mod download
        if ($LASTEXITCODE -ne 0) { Fail 'go mod download failed' 2 }

        & pulumi up --yes --stack $Stack
        if ($LASTEXITCODE -ne 0) { Fail 'pulumi up failed' 2 }
    } finally {
        Pop-Location
    }
    Log 'pulumi up complete' 'Green'
} else {
    Log 'Skipping pulumi (cluster expected to exist already)'
}

# ── 4. Wait for kubeconfig + vault-0 (same logic as bootstrap.ps1) ────────────
if (-not (Test-Path $Kubeconfig)) {
    Fail "kubeconfig not found at $Kubeconfig (Vagrant should have written it)" 3
}
$env:KUBECONFIG = $Kubeconfig
Log "Using kubeconfig: $Kubeconfig"

Log "Waiting for vault-0 pod to reach Running (timeout ${VaultWaitMinutes}m)"
$deadline = (Get-Date).AddMinutes($VaultWaitMinutes)
$phase    = ''
while ((Get-Date) -lt $deadline) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $raw = & kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2>&1
        $phase = if ($LASTEXITCODE -eq 0) { "$raw" } else { '' }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($phase -eq 'Running') {
        Log 'vault-0 pod is Running (sealed, ready for init)' 'Green'
        break
    }
    $disp = if ($phase) { $phase } else { 'NotFound (ArgoCD still applying)' }
    Log "  vault-0 phase: $disp" 'DarkGray'
    Start-Sleep 15
}
if ($phase -ne 'Running') {
    Fail "vault-0 did not reach Running within ${VaultWaitMinutes}m (last phase: '$phase')." 3
}

# ── 5. init-vault.ps1 (same script as the Terraform path) ─────────────────────
$initScript = Join-Path $PSScriptRoot 'init-vault.ps1'
Log "Running init-vault.ps1 (init + unseal + seed secrets)"
& $initScript
if ($LASTEXITCODE -ne 0) { Fail 'init-vault.ps1 failed' 4 }
Log 'Vault initialized + unsealed + seeded' 'Green'

# ── 6. (Optional) wait for every Argo Application Healthy ────────────────────
if ($WaitForHealthy) {
    Log "Waiting for all Argo Applications to reach Healthy (timeout ${AppsWaitMinutes}m)"
    $deadline = (Get-Date).AddMinutes($AppsWaitMinutes)
    $allHealthy = $false
    while ((Get-Date) -lt $deadline) {
        $apps = $null
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $json = & kubectl -n argocd get applications -o json 2>&1
            if ($LASTEXITCODE -eq 0) { $apps = $json | ConvertFrom-Json }
        } finally {
            $ErrorActionPreference = $prev
        }
        if (-not $apps) { Log '  applications CRD not ready yet' 'DarkGray'; Start-Sleep 15; continue }
        $byHealth = $apps.items | Group-Object { $_.status.health.status }
        $byHealth | ForEach-Object { Log "  $($_.Name): $($_.Count)" 'DarkGray' }
        $allHealthy = $apps.items.Count -gt 0 -and ($apps.items | Where-Object { $_.status.health.status -ne 'Healthy' }).Count -eq 0
        if ($allHealthy) {
            Log 'All Applications Healthy' 'Green'
            break
        }
        Start-Sleep 20
    }
    if (-not $allHealthy) {
        Fail "Apps not all Healthy within ${AppsWaitMinutes}m." 5
    }
}

# ── 7. Summary ────────────────────────────────────────────────────────────────
Log '' 'White'
Log '════════════════════════════════════════════════════════════════════════' 'White'
Log ' Cluster bootstrap COMPLETE (Pulumi path)' 'Green'
Log '════════════════════════════════════════════════════════════════════════' 'White'
Log ''
Log 'URLs (add to hosts file: 192.168.56.20 argocd.lab.test keycloak.lab.test minio.lab.test vault.lab.test)'
Log '  ArgoCD:    https://argocd.lab.test'
Log '  Keycloak:  https://keycloak.lab.test'
Log '  MinIO:     https://minio.lab.test'
Log '  Vault:     https://vault.lab.test'
Log ''
Log "Pulumi state lives under ~/.pulumi (stack: $Stack). 'pulumi stack output' lists exports."
Log ''
exit 0
