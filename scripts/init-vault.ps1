# Vault init, unseal, and secret seeding for the iac-rke2-keycloak lab.
#
# This script is IDEMPOTENT - safe to re-run. It will:
#   1. Wait for the Vault pod to be Ready
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
# Production note: this script is for the lab only. Real Vault deployments use:
#   - Shamir 5-of-3 keys distributed across operators
#   - Auto-unseal via KMS (AWS KMS, GCP KMS, Azure Key Vault, HSM)
#   - 3-node Raft HA cluster
#   - Secrets seeded by the application teams, not a single bootstrap script

$ErrorActionPreference = 'Stop'
$Namespace = 'vault'
$VaultPod  = 'vault-0'
$KeysFile  = Join-Path $PSScriptRoot '..\vault-keys.json'

function VaultExec {
    param([string[]]$Args)
    & kubectl -n $Namespace exec $VaultPod -- vault @Args
}

function VaultExecJson {
    param([string[]]$Args)
    $output = & kubectl -n $Namespace exec $VaultPod -- vault @Args -format=json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "vault $Args failed: $output" }
    return $output | Out-String | ConvertFrom-Json
}

function Log {
    param([string]$Msg, [string]$Color = 'Cyan')
    Write-Host "[init-vault] $Msg" -ForegroundColor $Color
}

# ── 1. Wait for Vault pod to be Ready ───────────────────────────────────────
Log 'Waiting for vault-0 pod to be Running (up to 5 min)...'
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $phase = & kubectl -n $Namespace get pod $VaultPod -o jsonpath='{.status.phase}' 2>$null
    if ($phase -eq 'Running') {
        Log 'vault-0 is Running' Green
        break
    }
    Start-Sleep 5
}
if ($phase -ne 'Running') {
    throw "vault-0 never reached Running state"
}

# ── 2. Inspect status ───────────────────────────────────────────────────────
$statusRaw = & kubectl -n $Namespace exec $VaultPod -- vault status -format=json 2>&1
# vault status returns exit code 2 when sealed - that is NOT an error for us
$status = $statusRaw | Out-String | ConvertFrom-Json
Log "Initialized: $($status.initialized)  Sealed: $($status.sealed)"

# ── 3. Initialize if not yet initialized ────────────────────────────────────
if (-not $status.initialized) {
    Log 'Vault is NOT initialized. Running operator init (1 share / 1 threshold).' Yellow
    $initResult = VaultExecJson operator,init,-key-shares=1,-key-threshold=1
    $initResult | ConvertTo-Json -Depth 5 | Set-Content $KeysFile
    Log "Init keys saved to: $KeysFile (gitignored)" Green
    Log "*** Save vault-keys.json - it is the ONLY way to unseal Vault after restart ***" Yellow
} else {
    Log 'Vault is already initialized.' Green
    if (-not (Test-Path $KeysFile)) {
        throw "Vault is initialized but $KeysFile is missing. Cannot unseal or seed without it. Either restore the file from a previous run, or kubectl delete pvc -n vault data-vault-0 and re-run to start fresh (WIPES DATA)."
    }
}

# ── 4. Unseal if sealed ─────────────────────────────────────────────────────
$keys = Get-Content $KeysFile -Raw | ConvertFrom-Json
$unsealKey = $keys.unseal_keys_b64[0]
$rootToken = $keys.root_token

$statusRaw = & kubectl -n $Namespace exec $VaultPod -- vault status -format=json 2>&1
$status = $statusRaw | Out-String | ConvertFrom-Json
if ($status.sealed) {
    Log 'Unsealing...'
    & kubectl -n $Namespace exec $VaultPod -- vault operator unseal $unsealKey | Out-Null
    Log 'Unsealed.' Green
} else {
    Log 'Already unsealed.' Green
}

# ── 5. Authenticate with root token ─────────────────────────────────────────
& kubectl -n $Namespace exec $VaultPod -- vault login $rootToken | Out-Null

# Helper to run vault command as authenticated client
function VaultAuth {
    param([string[]]$Args)
    & kubectl -n $Namespace exec $VaultPod -- env VAULT_TOKEN=$rootToken vault @Args 2>&1
}

# ── 6. Enable K8s auth method ───────────────────────────────────────────────
$authList = (VaultAuth auth,list,-format=json) | Out-String | ConvertFrom-Json
if (-not $authList.'kubernetes/') {
    Log 'Enabling Kubernetes auth method...'
    VaultAuth auth,enable,kubernetes | Out-Null
    # Configure it to talk to the K8s API
    VaultAuth write,auth/kubernetes/config,kubernetes_host="https://kubernetes.default.svc:443" | Out-Null
    Log 'Kubernetes auth method enabled and configured.' Green
} else {
    Log 'Kubernetes auth method already enabled.' Green
}

# ── 7. Enable KV v2 secrets engine at secret/ ───────────────────────────────
$secretsList = (VaultAuth secrets,list,-format=json) | Out-String | ConvertFrom-Json
if (-not $secretsList.'secret/') {
    Log 'Enabling KV v2 secrets engine at secret/...'
    VaultAuth secrets,enable,-path=secret,-version=2,kv | Out-Null
    Log 'KV v2 enabled.' Green
} else {
    Log 'KV v2 already mounted at secret/.' Green
}

# ── 8. Seed secrets (skip paths that already exist) ─────────────────────────
function NewPassword([int]$Length = 32) {
    -join ((48..57) + (65..90) + (97..122) | Get-Random -Count $Length | ForEach-Object { [char]$_ })
}

function SeedSecret {
    param([string]$Path, [hashtable]$Data)
    $check = VaultAuth kv,get,-format=json,"secret/$Path"
    if ($LASTEXITCODE -eq 0 -and $check -notmatch 'No value found') {
        Log "Skip (exists): secret/$Path" DarkGray
        return
    }
    $kvArgs = @("kv", "put", "secret/$Path") + ($Data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    VaultAuth @kvArgs | Out-Null
    Log "Seeded: secret/$Path" Green
}

Log 'Seeding initial secrets (skipping paths that already exist)...'
SeedSecret 'minio/admin'                 @{ user='minio-admin';   password=(NewPassword 32) }
SeedSecret 'minio/cnpg-access-keys'      @{ access_key='cnpg-bk-' + (NewPassword 12); secret_key=(NewPassword 40) }
SeedSecret 'minio/vault-snapshot-keys'   @{ access_key='vault-sn-' + (NewPassword 12); secret_key=(NewPassword 40) }
SeedSecret 'postgres/keycloak'           @{ user='keycloak';      password=(NewPassword 32) }
SeedSecret 'keycloak/admin'              @{ user='admin';         password=(NewPassword 32) }

# ── 9. Create the ESO policy ────────────────────────────────────────────────
$esoPolicy = @'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
'@

$esoPolicy | & kubectl -n $Namespace exec -i $VaultPod -- env VAULT_TOKEN=$rootToken vault policy write eso-secret-reader - | Out-Null
Log 'Policy eso-secret-reader written.' Green

# ── 10. Create K8s auth role for ESO ────────────────────────────────────────
# Bound to the ServiceAccount that Phase 7 will create:
#   namespace: external-secrets, ServiceAccount: external-secrets
VaultAuth write,auth/kubernetes/role/external-secrets,bound_service_account_names=external-secrets,bound_service_account_namespaces=external-secrets,policies=eso-secret-reader,ttl=24h | Out-Null
Log 'K8s auth role "external-secrets" created.' Green

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Log '═══════════════════════════════════════════════════════════════' Yellow
Log 'Vault init complete' Green
Log "  UI:           https://vault.lab.test" Green
Log "  Root token:   $rootToken" Yellow
Log "  Unseal key:   $unsealKey" Yellow
Log "  Keys file:    $KeysFile (KEEP SAFE - needed to unseal after restart)" Yellow
Log '═══════════════════════════════════════════════════════════════' Yellow
Log 'Sample - read a seeded secret:' Cyan
Log '  kubectl -n vault exec vault-0 -- env VAULT_TOKEN=' + $rootToken + ' vault kv get secret/keycloak/admin' DarkGray