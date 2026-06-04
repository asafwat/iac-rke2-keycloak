#!/usr/bin/env bash
# Vault init, unseal, and secret seeding for the iac-rke2-keycloak lab.
# Bash equivalent of scripts/ps/init-vault.ps1.
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
#
# Requires: kubectl, jq, openssl in PATH.

# Do NOT use 'set -e' - vault status legitimately exits 2 when sealed.
set -uo pipefail

NAMESPACE='vault'
VAULT_POD='vault-0'

# Resolve paths relative to script regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KEYS_FILE="$REPO_ROOT/vault-keys.json"
LAB_KUBECONFIG="$REPO_ROOT/kubeconfig"

# Color helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'
log()      { echo -e "${CYAN}[init-vault]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[init-vault]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[init-vault]${NC} $*"; }
log_dim()  { echo -e "${GRAY}[init-vault]${NC} $*"; }
err()      { echo -e "${RED}[init-vault] ERROR:${NC} $*" >&2; }

# Prereqs
for tool in kubectl jq openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        err "$tool not found in PATH"
        exit 1
    fi
done

if [[ ! -f "$LAB_KUBECONFIG" ]]; then
    err "Lab kubeconfig not found at $LAB_KUBECONFIG. Run 'terraform apply' first."
    exit 1
fi
export KUBECONFIG="$LAB_KUBECONFIG"
log_dim "Using kubeconfig: $LAB_KUBECONFIG"

# ── Helpers ─────────────────────────────────────────────────────────────────
#
# bash command-substitution runs in a subshell - so any VAULT_EXIT=... inside
# a function called via $(fn ...) would NOT propagate to the parent shell.
# Workaround: helpers write to global VAULT_OUTPUT and VAULT_EXIT directly
# (no subshell), and callers read those after each call.

VAULT_OUTPUT=""
VAULT_EXIT=0

# vault_exec [TOKEN] <args...>  -- if first arg looks like a hvs.* token, use it
vault_exec() {
    local token=""
    if [[ "${1:-}" == hvs.* || "${1:-}" == s.* ]]; then
        token="$1"; shift
    fi
    local cmd=(kubectl -n "$NAMESPACE" exec "$VAULT_POD" --)
    if [[ -n "$token" ]]; then
        cmd+=(env "VAULT_TOKEN=$token")
    fi
    cmd+=(vault "$@")
    VAULT_OUTPUT="$("${cmd[@]}" 2>/dev/null)"
    VAULT_EXIT=$?
}

# vault_exec_stdin TOKEN STDIN_DATA <args...>  -- stdin variant for 'vault policy write - '
vault_exec_stdin() {
    local token="$1"; shift
    local stdin_data="$1"; shift
    local cmd=(kubectl -n "$NAMESPACE" exec -i "$VAULT_POD" -- env "VAULT_TOKEN=$token" vault "$@")
    VAULT_OUTPUT="$(printf '%s' "$stdin_data" | "${cmd[@]}" 2>/dev/null)"
    VAULT_EXIT=$?
}

new_password() {
    local len="${1:-32}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

# ── 1. Wait for Vault pod to be Running ─────────────────────────────────────
log "Waiting for vault-0 pod to be Running (up to 5 min)..."
for _ in $(seq 1 60); do
    phase="$(kubectl -n "$NAMESPACE" get pod "$VAULT_POD" -o jsonpath='{.status.phase}' 2>/dev/null)"
    if [[ "$phase" == "Running" ]]; then
        log_ok "vault-0 is Running"
        break
    fi
    sleep 5
done
if [[ "${phase:-}" != "Running" ]]; then
    err "vault-0 never reached Running state"
    exit 1
fi

# ── 2. Inspect status ───────────────────────────────────────────────────────
vault_exec status -format=json
if [[ $VAULT_EXIT -ne 0 && $VAULT_EXIT -ne 2 ]]; then
    err "Unable to read vault status (exit $VAULT_EXIT): $VAULT_OUTPUT"
    exit 1
fi
status_json="$VAULT_OUTPUT"
initialized="$(echo "$status_json" | jq -r '.initialized')"
sealed="$(echo "$status_json"      | jq -r '.sealed')"
log "Initialized: $initialized  Sealed: $sealed"

# ── 3. Initialize if needed ─────────────────────────────────────────────────
if [[ "$initialized" != "true" ]]; then
    log_warn "Vault is NOT initialized. Running operator init (1 share / 1 threshold)."
    vault_exec operator init -key-shares=1 -key-threshold=1 -format=json
    if [[ $VAULT_EXIT -ne 0 ]]; then
        err "operator init failed: $VAULT_OUTPUT"
        exit 1
    fi
    echo "$VAULT_OUTPUT" > "$KEYS_FILE"
    log_ok "Init keys saved to: $KEYS_FILE (gitignored)"
    log_warn "*** Save vault-keys.json - it is the ONLY way to unseal Vault after restart ***"
else
    log_ok "Vault is already initialized."
    if [[ ! -f "$KEYS_FILE" ]]; then
        err "Vault is initialized but $KEYS_FILE is missing."
        err "Either restore it from a previous run, or 'kubectl -n vault delete pvc data-vault-0' and re-run (WIPES DATA)."
        exit 1
    fi
fi

UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' "$KEYS_FILE")"
ROOT_TOKEN="$(jq -r '.root_token'         "$KEYS_FILE")"

# ── 4. Unseal if needed ─────────────────────────────────────────────────────
status_json="$(vault_exec status -format=json)"
sealed="$(echo "$status_json" | jq -r '.sealed')"
if [[ "$sealed" == "true" ]]; then
    log "Unsealing..."
    out="$(vault_exec operator unseal "$UNSEAL_KEY")"
    if [[ $VAULT_EXIT -ne 0 ]]; then
        err "unseal failed: $out"
        exit 1
    fi
    log_ok "Unsealed."
else
    log_ok "Already unsealed."
fi

# ── 5. Enable K8s auth method ───────────────────────────────────────────────
auth_list="$(vault_exec "$ROOT_TOKEN" auth list -format=json)"
if ! echo "$auth_list" | jq -e '."kubernetes/"' >/dev/null 2>&1; then
    log "Enabling Kubernetes auth method..."
    vault_exec "$ROOT_TOKEN" auth enable kubernetes >/dev/null
    vault_exec "$ROOT_TOKEN" write auth/kubernetes/config "kubernetes_host=https://kubernetes.default.svc:443" >/dev/null
    log_ok "Kubernetes auth method enabled and configured."
else
    log_ok "Kubernetes auth method already enabled."
fi

# ── 6. Enable KV v2 ─────────────────────────────────────────────────────────
secrets_list="$(vault_exec "$ROOT_TOKEN" secrets list -format=json)"
if ! echo "$secrets_list" | jq -e '."secret/"' >/dev/null 2>&1; then
    log "Enabling KV v2 secrets engine at secret/..."
    vault_exec "$ROOT_TOKEN" secrets enable -path=secret -version=2 kv >/dev/null
    log_ok "KV v2 enabled."
else
    log_ok "KV v2 already mounted at secret/."
fi

# ── 7. Seed secrets (skip paths that already exist) ─────────────────────────
seed_secret() {
    local path="$1"; shift
    vault_exec "$ROOT_TOKEN" kv get "secret/$path" >/dev/null
    if [[ $VAULT_EXIT -eq 0 ]]; then
        log_dim "Skip (exists): secret/$path"
        return
    fi
    vault_exec "$ROOT_TOKEN" kv put "secret/$path" "$@" >/dev/null
    if [[ $VAULT_EXIT -ne 0 ]]; then
        err "kv put secret/$path failed"
        exit 1
    fi
    log_ok "Seeded: secret/$path"
}

log "Seeding initial secrets (skipping paths that already exist)..."
seed_secret 'minio/admin'                user='minio-admin'                                password="$(new_password 32)"
seed_secret 'minio/cnpg-access-keys'     access_key="cnpg-bk-$(new_password 12)"           secret_key="$(new_password 40)"
seed_secret 'minio/vault-snapshot-keys'  access_key="vault-sn-$(new_password 12)"          secret_key="$(new_password 40)"
seed_secret 'postgres/keycloak'          user='keycloak'                                   password="$(new_password 32)"
seed_secret 'keycloak/admin'             user='admin'                                      password="$(new_password 32)"
seed_secret 'grafana/admin'              user='admin'                                      password="$(new_password 32)"

# ── 8. Policy + role for ESO ────────────────────────────────────────────────
ESO_POLICY='path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}'

vault_exec_stdin "$ROOT_TOKEN" "$ESO_POLICY" policy write eso-secret-reader - >/dev/null
if [[ $VAULT_EXIT -ne 0 ]]; then
    err "policy write failed"
    exit 1
fi
log_ok "Policy eso-secret-reader written."

vault_exec "$ROOT_TOKEN" write auth/kubernetes/role/external-secrets \
    "bound_service_account_names=external-secrets" \
    "bound_service_account_namespaces=external-secrets" \
    "policies=eso-secret-reader" \
    "ttl=24h" >/dev/null
if [[ $VAULT_EXIT -ne 0 ]]; then
    err "role write failed"
    exit 1
fi
log_ok 'K8s auth role "external-secrets" created.'

# ── 9. Vault snapshot policy + role (Phase 11) ──────────────────────────────
# vault-backup CronJob authenticates as SA `vault-snapshot` in ns `vault`,
# then calls /v1/sys/storage/raft/snapshot.
SNAP_POLICY='path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}'

vault_exec_stdin "$ROOT_TOKEN" "$SNAP_POLICY" policy write vault-snapshot-policy - >/dev/null
if [[ $VAULT_EXIT -ne 0 ]]; then
    err "vault-snapshot-policy write failed"
    exit 1
fi
log_ok "Policy vault-snapshot-policy written."

vault_exec "$ROOT_TOKEN" write auth/kubernetes/role/vault-snapshot \
    "bound_service_account_names=vault-snapshot" \
    "bound_service_account_namespaces=vault" \
    "policies=vault-snapshot-policy" \
    "ttl=10m" >/dev/null
if [[ $VAULT_EXIT -ne 0 ]]; then
    err "vault-snapshot role write failed"
    exit 1
fi
log_ok 'K8s auth role "vault-snapshot" created.'

# ── Summary ─────────────────────────────────────────────────────────────────
echo
log_warn '═══════════════════════════════════════════════════════════════'
log_ok   'Vault init complete'
log_ok   "  UI:          https://vault.lab.test"
log_warn "  Root token:  $ROOT_TOKEN"
log_warn "  Unseal key:  $UNSEAL_KEY"
log_warn "  Keys file:   $KEYS_FILE (KEEP SAFE - needed to unseal after restart)"
log_warn '═══════════════════════════════════════════════════════════════'
log      'Sample - read a seeded secret:'
log_dim  "  kubectl -n vault exec vault-0 -- env VAULT_TOKEN=$ROOT_TOKEN vault kv get secret/keycloak/admin"