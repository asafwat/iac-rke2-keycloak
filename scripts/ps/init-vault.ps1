# Vault init, unseal, and secret seeding for the iac-rke2-keycloak lab.
#
# This script is IDEMPOTENT - safe to re-run. It will:
#   1. Wait for the Vault pod to be Running
#   2. Initialize Vault (1 unseal key, 1 threshold) if not already initialized
#      Saves the unseal key + root token to ../vault-keys.json (GITIGNORED)
#   3. Unseal Vault if sealed (reads the key from ../vault-keys.json)
#   4. Enable Kubernetes auth method (skip if already enabled)
#   5. Enable KV v2 secrets engine at secret/ (skip if already enabled)
#   6. Generate random passwords and write them to Vault paths
#      (skip individual paths that already exist - re-running won't rotate creds)
#   7. Create eso-secret-reader Vault policy
#   8. Create K8s auth role "external-secrets" bound to that policy
#
# Production note: lab-only. Real Vault uses Shamir 5/3, KMS auto-unseal, 3-node Raft HA.

# NOTE: We explicitly set $ErrorActionPreference = 'Continue' here, NOT
# 'Stop'. PowerShell 5.1 under EAP=Stop promotes any native-command stderr
# (even when redirected with 2>$null) into a terminating error -
# 'vault status' legitimately exits 2 when sealed, kubectl writes "namespace
# not found" to stderr while ArgoCD is still applying, and 'kv get' returns
# non-zero on a missing path. All of those are expected control flow; we
# check $LASTEXITCODE explicitly.
#
# We MUST set this explicitly because a parent script (bootstrap.ps1) sets
# EAP=Stop globally, and preference variables are inherited by called scripts.
$ErrorActionPreference = 'Continue'

$Namespace = 'vault'
$VaultPod  = 'vault-0'

# Resolve paths relative to the script regardless of the shell's CWD.
$RepoRoot      = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$KeysFile      = Join-Path $RepoRoot 'vault-keys.json'
$LabKubeconfig = Join-Path $RepoRoot 'kubeconfig'

if (-not (Test-Path $LabKubeconfig)) {
    Write-Error "Lab kubeconfig not found at $LabKubeconfig. Run 'terraform apply' first."
    exit 1
}
$env:KUBECONFIG = $LabKubeconfig

function Log {
    param([string]$Msg, [string]$Color = 'Cyan')
    Write-Host "[init-vault] $Msg" -ForegroundColor $Color
}

Log "Using kubeconfig: $LabKubeconfig" 'DarkGray'

# ── Helpers ─────────────────────────────────────────────────────────────────

# Runs `vault <args>` inside the vault-0 pod, captures stdout, swallows stderr.
# Returns @{ Output, ExitCode }. Caller decides what to do with the exit code.
#
# NOTE: parameter is named $VaultArgs (not $Args) - $Args is a PowerShell
# automatic variable and shadowing it inside a function caused arg-passing
# breakage on PowerShell 5.1.
function VaultExec {
    param([string[]]$VaultArgs, [string]$Token = $null)
    $cmd = @('-n', $Namespace, 'exec', $VaultPod, '--')
    if ($Token) {
        $cmd += @('env', "VAULT_TOKEN=$Token")
    }
    $cmd += 'vault'
    $cmd += $VaultArgs
    $output = & kubectl @cmd 2>$null
    return @{ Output = ($output | Out-String); ExitCode = $LASTEXITCODE }
}

# ── 1. Wait for vault-0 pod to reach Running ────────────────────────────────
# Do NOT wait for ArgoCD's vault Application to be Healthy: ArgoCD considers
# a StatefulSet Healthy only when its pod is Ready 1/1, but Vault's readiness
# probe FAILS while sealed - and this script is what unseals it. Waiting on
# Application Healthy is a deadlock.
#
# Pod-phase Running is the correct signal: the container is up, Vault listens
# on :8200, ready to receive init/unseal API calls.
Log 'Waiting for vault-0 pod to reach Running (up to 10 min)...'
$deadline = (Get-Date).AddMinutes(10)
$phase    = ''
while ((Get-Date) -lt $deadline) {
    $phase = (& kubectl -n $Namespace get pod $VaultPod -o jsonpath='{.status.phase}' 2>$null)
    if ($phase -eq 'Running') {
        Log "$VaultPod pod phase: Running (sealed, ready for init)" Green
        break
    }
    if ($phase) {
        Log "$VaultPod pod phase: $phase (waiting for Running)" DarkGray
    } else {
        Log "$VaultPod not yet present (ArgoCD still applying / pod still scheduling)" DarkGray
    }
    Start-Sleep 10
}
if ($phase -ne 'Running') {
    Write-Error "$VaultPod never reached Running. Last phase: '$phase'. Check 'kubectl -n $Namespace describe pod $VaultPod' and 'kubectl -n argocd get app vault'."
    exit 1
}

# ── 2. Inspect status ───────────────────────────────────────────────────────
# Exit codes from `vault status`:  0 = unsealed, 1 = error, 2 = sealed
$statusResult = VaultExec @('status', '-format=json')
if ($statusResult.ExitCode -notin 0, 2) {
    Write-Error "Unable to read vault status (exit $($statusResult.ExitCode)): $($statusResult.Output)"
    exit 1
}
$status = $statusResult.Output | ConvertFrom-Json
Log "Initialized: $($status.initialized)  Sealed: $($status.sealed)"

# ── 3. Initialize if needed ─────────────────────────────────────────────────
if (-not $status.initialized) {
    Log 'Vault is NOT initialized. Running operator init (1 share / 1 threshold).' Yellow
    $initResult = VaultExec @('operator', 'init', '-key-shares=1', '-key-threshold=1', '-format=json')
    if ($initResult.ExitCode -ne 0) {
        Write-Error "operator init failed: $($initResult.Output)"
        exit 1
    }
    $initResult.Output | Set-Content $KeysFile
    Log "Init keys saved to: $KeysFile (gitignored)" Green
    Log '*** Save vault-keys.json - it is the ONLY way to unseal Vault after restart ***' Yellow
} else {
    Log 'Vault is already initialized.' Green
    if (-not (Test-Path $KeysFile)) {
        Write-Error "Vault is initialized but $KeysFile is missing. Cannot unseal or seed without it. Either restore the file from a previous run, or 'kubectl -n vault delete pvc data-vault-0' and re-run (WIPES DATA)."
        exit 1
    }
}

$keys = Get-Content $KeysFile -Raw | ConvertFrom-Json
$unsealKey = $keys.unseal_keys_b64[0]
$rootToken = $keys.root_token

# ── 4. Unseal if needed ─────────────────────────────────────────────────────
$statusResult = VaultExec @('status', '-format=json')
$status = $statusResult.Output | ConvertFrom-Json
if ($status.sealed) {
    Log 'Unsealing...'
    $unsealResult = VaultExec @('operator', 'unseal', $unsealKey)
    if ($unsealResult.ExitCode -ne 0) {
        Write-Error "unseal failed: $($unsealResult.Output)"
        exit 1
    }
    Log 'Unsealed.' Green
} else {
    Log 'Already unsealed.' Green
}

# ── 5. Enable K8s auth method ───────────────────────────────────────────────
$authList = (VaultExec @('auth', 'list', '-format=json') -Token $rootToken).Output | ConvertFrom-Json
if (-not $authList.'kubernetes/') {
    Log 'Enabling Kubernetes auth method...'
    (VaultExec @('auth', 'enable', 'kubernetes') -Token $rootToken) | Out-Null
    (VaultExec @('write', 'auth/kubernetes/config', 'kubernetes_host=https://kubernetes.default.svc:443') -Token $rootToken) | Out-Null
    Log 'Kubernetes auth method enabled and configured.' Green
} else {
    Log 'Kubernetes auth method already enabled.' Green
}

# ── 6. Enable KV v2 ─────────────────────────────────────────────────────────
$secretsList = (VaultExec @('secrets', 'list', '-format=json') -Token $rootToken).Output | ConvertFrom-Json
if (-not $secretsList.'secret/') {
    Log 'Enabling KV v2 secrets engine at secret/...'
    (VaultExec @('secrets', 'enable', '-path=secret', '-version=2', 'kv') -Token $rootToken) | Out-Null
    Log 'KV v2 enabled.' Green
} else {
    Log 'KV v2 already mounted at secret/.' Green
}

# ── 7. Seed secrets (skip paths that already exist) ─────────────────────────
function NewPassword([int]$Length = 32) {
    -join ((48..57) + (65..90) + (97..122) | Get-Random -Count $Length | ForEach-Object { [char]$_ })
}

function SeedSecret {
    param([string]$Path, [hashtable]$Data)
    $check = VaultExec @('kv', 'get', "secret/$Path") -Token $rootToken
    if ($check.ExitCode -eq 0) {
        Log "Skip (exists): secret/$Path" DarkGray
        return
    }
    $kvArgs = @('kv', 'put', "secret/$Path") + ($Data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    $putResult = VaultExec $kvArgs -Token $rootToken
    if ($putResult.ExitCode -ne 0) {
        Write-Error "kv put secret/$Path failed: $($putResult.Output)"
        exit 1
    }
    Log "Seeded: secret/$Path" Green
}

Log 'Seeding initial secrets (skipping paths that already exist)...'
SeedSecret 'minio/admin'                @{ user='minio-admin';                          password=(NewPassword 32) }
SeedSecret 'minio/cnpg-access-keys'     @{ access_key=('cnpg-bk-'  + (NewPassword 12)); secret_key=(NewPassword 40) }
SeedSecret 'minio/vault-snapshot-keys'  @{ access_key=('vault-sn-' + (NewPassword 12)); secret_key=(NewPassword 40) }
SeedSecret 'postgres/keycloak'          @{ user='keycloak';                             password=(NewPassword 32) }
SeedSecret 'keycloak/admin'             @{ user='admin';                                password=(NewPassword 32) }
SeedSecret 'grafana/admin'              @{ user='admin';                                password=(NewPassword 32) }

# ── 8. Policy + role for ESO ────────────────────────────────────────────────
# Use a tempfile + kubectl cp rather than stdin piping - PowerShell's
# pipe-to-native-command stdin handling is unreliable for multi-line content.

$esoPolicy = @'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
'@

# Encode policy as base64; decode inside the pod, apply by file path.
# Avoids both PS stdin piping and kubectl cp (the latter trips on Windows 'C:' paths).
$policyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($esoPolicy))
$shellCmd  = "echo '$policyB64' | base64 -d > /tmp/eso.hcl && " +
             "env VAULT_TOKEN=$rootToken vault policy write eso-secret-reader /tmp/eso.hcl && " +
             "rm -f /tmp/eso.hcl"

$polOutput = & kubectl -n $Namespace exec $VaultPod -- sh -c $shellCmd 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "policy write failed: $polOutput"
    exit 1
}

Log 'Policy eso-secret-reader written.' Green

# K8s auth role bound to the SA Phase 7 will create.
$roleResult = VaultExec @(
    'write', 'auth/kubernetes/role/external-secrets',
    'bound_service_account_names=external-secrets',
    'bound_service_account_namespaces=external-secrets',
    'policies=eso-secret-reader',
    'ttl=24h'
) -Token $rootToken
if ($roleResult.ExitCode -ne 0) {
    Write-Error "role write failed: $($roleResult.Output)"
    exit 1
}
Log 'K8s auth role "external-secrets" created.' Green

# ── 9. Vault snapshot policy + role (Phase 11) ──────────────────────────────
# The vault-backup CronJob (manifests/vault-backup/cronjob.yaml) authenticates
# via the kubernetes auth method as SA `vault-snapshot` in ns `vault`, then
# calls /v1/sys/storage/raft/snapshot which requires sudo on that path.

$snapPolicy = @'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
'@

$snapPolicyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($snapPolicy))
$snapShellCmd  = "echo '$snapPolicyB64' | base64 -d > /tmp/snap.hcl && " +
                 "env VAULT_TOKEN=$rootToken vault policy write vault-snapshot-policy /tmp/snap.hcl && " +
                 "rm -f /tmp/snap.hcl"

$snapPolOutput = & kubectl -n $Namespace exec $VaultPod -- sh -c $snapShellCmd 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "vault-snapshot-policy write failed: $snapPolOutput"
    exit 1
}
Log 'Policy vault-snapshot-policy written.' Green

$snapRoleResult = VaultExec @(
    'write', 'auth/kubernetes/role/vault-snapshot',
    'bound_service_account_names=vault-snapshot',
    'bound_service_account_namespaces=vault',
    'policies=vault-snapshot-policy',
    'ttl=10m'
) -Token $rootToken
if ($snapRoleResult.ExitCode -ne 0) {
    Write-Error "vault-snapshot role write failed: $($snapRoleResult.Output)"
    exit 1
}
Log 'K8s auth role "vault-snapshot" created.' Green

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host ''
Log '═══════════════════════════════════════════════════════════════' Yellow
Log 'Vault init complete' Green
Log "  UI:          https://vault.lab.test" Green
Log "  Root token:  $rootToken" Yellow
Log "  Unseal key:  $unsealKey" Yellow
Log "  Keys file:   $KeysFile (KEEP SAFE - needed to unseal after restart)" Yellow
Log '═══════════════════════════════════════════════════════════════' Yellow
Log 'Sample - read a seeded secret:' Cyan
$cmd = "kubectl -n vault exec vault-0 -- env VAULT_TOKEN=$rootToken vault kv get secret/keycloak/admin"
Log "  $cmd" DarkGray