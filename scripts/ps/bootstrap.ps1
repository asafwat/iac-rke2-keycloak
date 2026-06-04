#requires -Version 5.1
# ──────────────────────────────────────────────────────────────────────────────
# bootstrap.ps1 — one-command end-to-end deploy (Windows / PowerShell)
#
# Pipeline:
#   1. Sanity-check tools on PATH (vagrant, terraform, kubectl, helm)
#   2. terraform init + apply  → VM + RKE2 + ArgoCD + root Application
#   3. Wait for vault-0 pod to reach phase=Running (sealed but reachable)
#   4. Run init-vault.ps1       → init + unseal + seed secrets + ESO role
#   5. (Optional) Wait for every Argo Application to reach Healthy + Synced
#   6. Print summary: URLs, retrieval commands for credentials
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap.ps1 -WaitForHealthy
#   powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap.ps1 -SkipTerraform
#
# Exit codes:
#   0 = success
#   1 = pre-flight failure (missing tool)
#   2 = terraform apply failed
#   3 = vault-0 never reached Running
#   4 = init-vault.ps1 failed
#   5 = Argo apps didn't all reach Healthy within timeout (only when -WaitForHealthy)
# ──────────────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    [switch]$SkipTerraform,         # Skip terraform apply (cluster already exists)
    [switch]$WaitForHealthy,        # Wait for all Argo apps to reach Healthy (slow)
    [int]   $VaultWaitMinutes = 20,
    [int]   $AppsWaitMinutes  = 25
)

$ErrorActionPreference = 'Stop'
$RepoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
$Kubeconfig = Join-Path $RepoRoot 'kubeconfig'

function Log {
    param([string]$Msg, [string]$Color = 'Cyan')
    Write-Host "[bootstrap] $Msg" -ForegroundColor $Color
}
function Fail {
    param([string]$Msg, [int]$ExitCode)
    Write-Host "[bootstrap] FAILED: $Msg" -ForegroundColor Red
    exit $ExitCode
}

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
Log 'Pre-flight: checking tools on PATH'
$tools = @('vagrant','terraform','kubectl','helm')
$missing = @()
foreach ($t in $tools) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
}
if ($missing.Count -gt 0) {
    Fail "missing tool(s) on PATH: $($missing -join ', '). Install per README prerequisites." 1
}
Log 'Pre-flight OK' 'Green'

# ── 2. Terraform apply ────────────────────────────────────────────────────────
if (-not $SkipTerraform) {
    Log 'terraform init + apply (this builds the VM + installs RKE2 + ArgoCD)'
    Push-Location (Join-Path $RepoRoot 'terraform')
    try {
        & terraform init -upgrade -input=false
        if ($LASTEXITCODE -ne 0) { Fail 'terraform init failed' 2 }
        & terraform apply -auto-approve -input=false
        if ($LASTEXITCODE -ne 0) { Fail 'terraform apply failed' 2 }
    } finally {
        Pop-Location
    }
    Log 'terraform apply complete' 'Green'
} else {
    Log 'Skipping terraform (cluster expected to exist already)'
}

# ── 3. Wait for kubeconfig + vault-0 ──────────────────────────────────────────
if (-not (Test-Path $Kubeconfig)) {
    Fail "kubeconfig not found at $Kubeconfig (Vagrant should have written it)" 3
}
$env:KUBECONFIG = $Kubeconfig
Log "Using kubeconfig: $Kubeconfig"

Log "Waiting for vault-0 pod to reach Running (timeout ${VaultWaitMinutes}m)"
$deadline = (Get-Date).AddMinutes($VaultWaitMinutes)
$phase    = ''
# Scope EAP locally: PS 5.1 wraps native-command stderr as NativeCommandError
# under EAP=Stop, which surfaces as a noisy error every poll while the
# vault namespace doesn't exist yet (ArgoCD still applying). Drop to
# SilentlyContinue around the kubectl call and key off $LASTEXITCODE.
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
    Fail "vault-0 did not reach Running within ${VaultWaitMinutes}m (last phase: '$phase'). Check 'kubectl -n vault describe pod vault-0' and 'kubectl -n argocd get applications'." 3
}

# ── 4. init-vault.ps1 ─────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot 'init-vault.ps1'
Log "Running init-vault.ps1 (init + unseal + seed secrets)"
& $initScript
if ($LASTEXITCODE -ne 0) { Fail 'init-vault.ps1 failed' 4 }
Log 'Vault initialized + unsealed + seeded' 'Green'

# ── 5. (Optional) wait for every Argo Application Healthy ────────────────────
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
        $degraded = ($apps.items | Where-Object { $_.status.health.status -ne 'Healthy' } | ForEach-Object { $_.metadata.name }) -join ', '
        Fail "Apps not all Healthy within ${AppsWaitMinutes}m. Not Healthy: $degraded" 5
    }
}

# ── 6. Summary ────────────────────────────────────────────────────────────────
Log '' 'White'
Log '════════════════════════════════════════════════════════════════════════' 'White'
Log ' Cluster bootstrap COMPLETE' 'Green'
Log '════════════════════════════════════════════════════════════════════════' 'White'
Log ''
Log 'URLs (add to your hosts file: 192.168.56.20 argocd.lab.test keycloak.lab.test minio.lab.test vault.lab.test grafana.lab.test)'
Log '  ArgoCD:    https://argocd.lab.test'
Log '  Keycloak:  https://keycloak.lab.test'
Log '  MinIO:     https://minio.lab.test           (S3 console)'
Log '  MinIO API: https://minio-api.lab.test'
Log '  Vault:     https://vault.lab.test'
Log '  Grafana:   https://grafana.lab.test         (only if Phase D / monitoring stack deployed)'
Log ''
Log 'Retrieve admin credentials:'
Log '  ArgoCD:   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}'
Log '  Keycloak: kubectl -n keycloak get secret keycloak-bootstrap-admin -o jsonpath="{.data.password}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}'
Log '  MinIO:    kubectl -n minio    get secret minio-root-credentials  -o jsonpath="{.data.root-password}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}'
Log '  Vault:    Get-Content terraform\vault-keys.json | ConvertFrom-Json | Select-Object -ExpandProperty root_token'
Log '  Grafana:  kubectl -n monitoring get secret grafana-admin -o jsonpath="{.data.admin-password}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}'
Log ''
Log 'Trust the lab CA to eliminate browser warnings - see README "Trust the lab CA".'
Log ''
exit 0
