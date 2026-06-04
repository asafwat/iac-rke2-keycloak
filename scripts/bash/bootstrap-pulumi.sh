#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# bootstrap-pulumi.sh — Pulumi+Go equivalent of bootstrap.sh.
#
# Same end state as the Terraform path: VM + RKE2 + ArgoCD + root Application
# + every workload reconciled by ArgoCD. Only the IaC step differs:
# `pulumi up` instead of `terraform apply`.
#
# DO NOT run alongside bootstrap.sh — both target the same VirtualBox VM
# name (rke2-server-1) and host-only IP. Pick one per session.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PULUMI_DIR="$REPO_ROOT/pulumi"
KUBECONFIG_FILE="$REPO_ROOT/kubeconfig"
SKIP_PULUMI=false
WAIT_FOR_HEALTHY=false
VAULT_WAIT_MIN=20
APPS_WAIT_MIN=25
STACK="dev"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-pulumi)       SKIP_PULUMI=true; shift ;;
        --wait-for-healthy)  WAIT_FOR_HEALTHY=true; shift ;;
        --vault-wait)        VAULT_WAIT_MIN="$2"; shift 2 ;;
        --apps-wait)         APPS_WAIT_MIN="$2";  shift 2 ;;
        --stack)             STACK="$2"; shift 2 ;;
        -h|--help)           sed -n '3,17p' "$0"; exit 0 ;;
        *) echo "[bootstrap-pulumi] unknown flag: $1" >&2; exit 1 ;;
    esac
done

log()  { printf '[bootstrap-pulumi] %s\n' "$*"; }
ok()   { printf '\033[0;32m[bootstrap-pulumi] %s\033[0m\n' "$*"; }
gray() { printf '\033[0;90m[bootstrap-pulumi]   %s\033[0m\n' "$*"; }
fail() { printf '\033[0;31m[bootstrap-pulumi] FAILED: %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
log 'Pre-flight: checking tools on PATH'
missing=()
for t in vagrant pulumi go kubectl helm; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    fail "missing tool(s) on PATH: ${missing[*]}" 1
fi
ok 'Pre-flight OK'

# ── 2. Passphrase ─────────────────────────────────────────────────────────────
if [[ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ]]; then
    log 'PULUMI_CONFIG_PASSPHRASE not set — using lab default. Override before any real workload.'
    export PULUMI_CONFIG_PASSPHRASE='lab-passphrase-change-me'
fi

# ── 3. Pulumi up ──────────────────────────────────────────────────────────────
if [[ "$SKIP_PULUMI" != true ]]; then
    log "pulumi up (this builds the VM + installs RKE2 + ArgoCD; stack=$STACK)"
    pushd "$PULUMI_DIR" >/dev/null
    pulumi login --local                                                || fail 'pulumi login --local failed' 2
    pulumi stack select "$STACK" 2>/dev/null || pulumi stack init "$STACK" || fail "pulumi stack init failed" 2
    go mod download                                                     || fail 'go mod download failed' 2
    pulumi up --yes --stack "$STACK"                                    || fail 'pulumi up failed' 2
    popd >/dev/null
    ok 'pulumi up complete'
else
    log 'Skipping pulumi (cluster expected to exist already)'
fi

# ── 4. Wait for kubeconfig + vault-0 ──────────────────────────────────────────
[[ -f "$KUBECONFIG_FILE" ]] || fail "kubeconfig not found at $KUBECONFIG_FILE" 3
export KUBECONFIG="$KUBECONFIG_FILE"

log "Waiting for vault-0 pod to reach Running (timeout ${VAULT_WAIT_MIN}m)"
deadline=$(( $(date +%s) + VAULT_WAIT_MIN*60 ))
phase=''
while [[ $(date +%s) -lt $deadline ]]; do
    phase="$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Running" ]]; then
        ok 'vault-0 pod is Running'
        break
    fi
    gray "vault-0 phase: ${phase:-NotFound}"
    sleep 15
done
[[ "$phase" == "Running" ]] || fail "vault-0 did not reach Running within ${VAULT_WAIT_MIN}m" 3

# ── 5. init-vault.sh (same script as the Terraform path) ──────────────────────
log 'Running init-vault.sh'
bash "$SCRIPT_DIR/init-vault.sh" || fail 'init-vault.sh failed' 4
ok 'Vault initialized'

# ── 6. (Optional) wait for healthy ────────────────────────────────────────────
if [[ "$WAIT_FOR_HEALTHY" == true ]]; then
    log "Waiting for all Argo Applications Healthy (timeout ${APPS_WAIT_MIN}m)"
    deadline=$(( $(date +%s) + APPS_WAIT_MIN*60 ))
    all_healthy=false
    while [[ $(date +%s) -lt $deadline ]]; do
        statuses="$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.status.health.status}{"\n"}{end}' 2>/dev/null || true)"
        not_healthy="$(echo "$statuses" | grep -v '=Healthy$' || true)"
        if [[ -z "$not_healthy" && -n "$statuses" ]]; then
            ok 'All Applications Healthy'
            all_healthy=true
            break
        fi
        gray "Not yet healthy: $(echo "$not_healthy" | tr '\n' ' ')"
        sleep 20
    done
    [[ "$all_healthy" == true ]] || fail "Apps not all Healthy within ${APPS_WAIT_MIN}m" 5
fi

# ── 7. Summary ────────────────────────────────────────────────────────────────
cat <<EOF

════════════════════════════════════════════════════════════════════════
 Cluster bootstrap COMPLETE (Pulumi path)
════════════════════════════════════════════════════════════════════════

Pulumi state: ~/.pulumi  (stack: $STACK)
List outputs: pulumi stack output --stack $STACK

URLs (add to /etc/hosts: 192.168.56.20 argocd.lab.test keycloak.lab.test minio.lab.test vault.lab.test):
  ArgoCD:    https://argocd.lab.test
  Keycloak:  https://keycloak.lab.test
  MinIO:     https://minio.lab.test
  Vault:     https://vault.lab.test

EOF
exit 0
