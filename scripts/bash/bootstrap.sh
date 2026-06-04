#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# bootstrap.sh — one-command end-to-end deploy (Linux / macOS / bash)
#
# Mirror of bootstrap.ps1; same pipeline:
#   1. Sanity-check tools on PATH (vagrant, terraform, kubectl, helm)
#   2. terraform init + apply  -> VM + RKE2 + ArgoCD + root Application
#   3. Wait for vault-0 pod to reach phase=Running
#   4. Run init-vault.sh        -> init + unseal + seed secrets + ESO role
#   5. (Optional) Wait for every Argo Application to reach Healthy
#   6. Print summary
#
# Usage:
#   ./scripts/bash/bootstrap.sh                          # default flow
#   ./scripts/bash/bootstrap.sh --wait-for-healthy       # also wait for apps Healthy
#   ./scripts/bash/bootstrap.sh --skip-terraform         # cluster already exists
#
# Exit codes match bootstrap.ps1 (1..5).
# Tested on native bash 5+ (Ubuntu/Debian/macOS). Git Bash on Windows is
# unsupported here - use bootstrap.ps1 on Windows.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KUBECONFIG_FILE="$REPO_ROOT/kubeconfig"
SKIP_TERRAFORM=false
WAIT_FOR_HEALTHY=false
VAULT_WAIT_MIN=20
APPS_WAIT_MIN=25

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-terraform)    SKIP_TERRAFORM=true; shift ;;
        --wait-for-healthy)  WAIT_FOR_HEALTHY=true; shift ;;
        --vault-wait)        VAULT_WAIT_MIN="$2"; shift 2 ;;
        --apps-wait)         APPS_WAIT_MIN="$2";  shift 2 ;;
        -h|--help)
            sed -n '3,25p' "$0"
            exit 0
            ;;
        *) echo "[bootstrap] unknown flag: $1" >&2; exit 1 ;;
    esac
done

log()   { printf '[bootstrap] %s\n' "$*"; }
ok()    { printf '\033[0;32m[bootstrap] %s\033[0m\n' "$*"; }
gray()  { printf '\033[0;90m[bootstrap]   %s\033[0m\n' "$*"; }
fail()  { printf '\033[0;31m[bootstrap] FAILED: %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
log 'Pre-flight: checking tools on PATH'
missing=()
for t in vagrant terraform kubectl helm; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    fail "missing tool(s) on PATH: ${missing[*]}. Install per README prerequisites." 1
fi
ok 'Pre-flight OK'

# ── 2. Terraform apply ────────────────────────────────────────────────────────
if [[ "$SKIP_TERRAFORM" != true ]]; then
    log 'terraform init + apply (this builds the VM + installs RKE2 + ArgoCD)'
    pushd "$REPO_ROOT/terraform" >/dev/null
    terraform init -upgrade -input=false || fail 'terraform init failed' 2
    terraform apply -auto-approve -input=false || fail 'terraform apply failed' 2
    popd >/dev/null
    ok 'terraform apply complete'
else
    log 'Skipping terraform (cluster expected to exist already)'
fi

# ── 3. Wait for kubeconfig + vault-0 ──────────────────────────────────────────
[[ -f "$KUBECONFIG_FILE" ]] || fail "kubeconfig not found at $KUBECONFIG_FILE (Vagrant should have written it)" 3
export KUBECONFIG="$KUBECONFIG_FILE"
log "Using kubeconfig: $KUBECONFIG_FILE"

log "Waiting for vault-0 pod to reach Running (timeout ${VAULT_WAIT_MIN}m)"
deadline=$(( $(date +%s) + VAULT_WAIT_MIN*60 ))
phase=''
while [[ $(date +%s) -lt $deadline ]]; do
    phase="$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Running" ]]; then
        ok 'vault-0 pod is Running (sealed, ready for init)'
        break
    fi
    gray "vault-0 phase: ${phase:-NotFound (ArgoCD still applying)}"
    sleep 15
done
[[ "$phase" == "Running" ]] || fail "vault-0 did not reach Running within ${VAULT_WAIT_MIN}m (last phase: '$phase')" 3

# ── 4. init-vault.sh ──────────────────────────────────────────────────────────
log 'Running init-vault.sh (init + unseal + seed secrets)'
bash "$SCRIPT_DIR/init-vault.sh" || fail 'init-vault.sh failed' 4
ok 'Vault initialized + unsealed + seeded'

# ── 5. (Optional) wait for every Argo Application Healthy ─────────────────────
if [[ "$WAIT_FOR_HEALTHY" == true ]]; then
    log "Waiting for all Argo Applications to reach Healthy (timeout ${APPS_WAIT_MIN}m)"
    deadline=$(( $(date +%s) + APPS_WAIT_MIN*60 ))
    all_healthy=false
    while [[ $(date +%s) -lt $deadline ]]; do
        statuses="$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.status.health.status}{"\n"}{end}')"
        not_healthy="$(echo "$statuses" | grep -v '=Healthy$' || true)"
        if [[ -z "$not_healthy" ]]; then
            ok 'All Applications Healthy'
            all_healthy=true
            break
        fi
        gray "Not yet healthy: $(echo "$not_healthy" | tr '\n' ' ')"
        sleep 20
    done
    [[ "$all_healthy" == true ]] || fail "Apps not all Healthy within ${APPS_WAIT_MIN}m. Not Healthy: $(echo "$not_healthy" | tr '\n' ' ')" 5
fi

# ── 6. Summary ────────────────────────────────────────────────────────────────
cat <<'EOF'

════════════════════════════════════════════════════════════════════════
 Cluster bootstrap COMPLETE
════════════════════════════════════════════════════════════════════════

URLs (add to /etc/hosts:
  192.168.56.20 argocd.lab.test keycloak.lab.test minio.lab.test vault.lab.test grafana.lab.test)

  ArgoCD:    https://argocd.lab.test
  Keycloak:  https://keycloak.lab.test
  MinIO:     https://minio.lab.test           (S3 console)
  MinIO API: https://minio-api.lab.test
  Vault:     https://vault.lab.test
  Grafana:   https://grafana.lab.test         (only if Phase D / monitoring stack deployed)

Retrieve admin credentials:
  ArgoCD:   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo
  Keycloak: kubectl -n keycloak get secret keycloak-bootstrap-admin   -o jsonpath='{.data.password}' | base64 -d ; echo
  MinIO:    kubectl -n minio    get secret minio-root-credentials     -o jsonpath='{.data.root-password}' | base64 -d ; echo
  Vault:    jq -r .root_token terraform/vault-keys.json
  Grafana:  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d ; echo

Trust the lab CA to eliminate browser warnings - see README "Trust the lab CA".

EOF
exit 0
