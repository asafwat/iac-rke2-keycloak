# Single-node openSUSE Leap 15.6 VM for RKE2.
#
# Vars read from environment so Terraform passes them through.
# To swap to Ubuntu fallback manually:  VM_BOX=ubuntu/jammy64 vagrant up
#
# Provisioner phases (idempotent):
#   1. Baseline packages (procps, hostname, iptables, curl)
#   2. OS prep for K8s (firewalld off, swap off, kernel modules, sysctl)
#   3. RKE2 single-node server install + start + wait for node Ready
#   4. Export kubeconfig with VM IP to /vagrant/kubeconfig (host repo root)

VM_BOX      = ENV['VM_BOX']      || 'opensuse/Leap-15.6.x86_64'
VM_MEMORY   = (ENV['VM_MEMORY']  || '12288').to_i
VM_CPUS     = (ENV['VM_CPUS']    || '8').to_i
VM_IP       = ENV['VM_IP']       || '192.168.56.10'
VM_HOSTNAME  = ENV['VM_HOSTNAME']  || 'rke2-server-1'
RKE2_VERSION = ENV['RKE2_VERSION'] || 'v1.35.5+rke2r2'

Vagrant.configure('2') do |config|
  config.vm.box      = VM_BOX
  config.vm.hostname = VM_HOSTNAME
  config.vm.network 'private_network', ip: VM_IP

  config.vm.provider 'virtualbox' do |vb|
    vb.name   = VM_HOSTNAME
    vb.memory = VM_MEMORY
    vb.cpus   = VM_CPUS
    vb.customize ['modifyvm', :id, '--audio-driver', 'none']
    vb.customize ['modifyvm', :id, '--usb',          'off']
  end

  config.vm.provision 'shell',
    env: {
      'VM_IP'        => VM_IP,
      'VM_HOSTNAME'  => VM_HOSTNAME,
      'RKE2_VERSION' => RKE2_VERSION,
    },
    inline: <<~SHELL
      set -eu

      echo '[prep] installing baseline packages (procps, hostname, iptables, curl)'
      install_pkgs() {
        if command -v zypper >/dev/null 2>&1; then
          zypper --non-interactive --quiet install -y procps hostname iptables curl ca-certificates >/dev/null
        elif command -v apt-get >/dev/null 2>&1; then
          DEBIAN_FRONTEND=noninteractive apt-get update -qq
          DEBIAN_FRONTEND=noninteractive apt-get install -y -qq procps hostname iptables curl ca-certificates >/dev/null
        fi
      }
      for i in 1 2 3; do
        install_pkgs && break
        echo "[prep] package install attempt $i failed, retrying in 10s..."
        sleep 10
      done

      echo '[prep] disabling firewalld'
      systemctl disable --now firewalld 2>/dev/null || true

      echo '[prep] disabling swap'
      swapoff -a
      sed -i '/swap/d' /etc/fstab

      echo '[prep] loading kernel modules'
      cat >/etc/modules-load.d/k8s.conf <<EOF
      br_netfilter
      overlay
      EOF
      modprobe br_netfilter
      modprobe overlay

      echo '[prep] sysctl for k8s networking + inotify limits'
      # openSUSE defaults: max_user_instances=128, max_user_watches=8192.
      # Too low for a multi-controller cluster (ArgoCD + cert-manager + ESO +
      # CNPG + Keycloak + Vault all consume watches). Symptoms when exhausted:
      # "failed to create fsnotify watcher: too many open files" - random
      # controllers lose their watches and stall.
      cat >/etc/sysctl.d/99-k8s.conf <<EOF
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1
      fs.inotify.max_user_instances       = 8192
      fs.inotify.max_user_watches         = 524288
      EOF
      sysctl --system

      echo '[prep] complete'

      # ── RKE2 install ──────────────────────────────────────────────────
      echo '[rke2] writing /etc/rancher/rke2/config.yaml'
      mkdir -p /etc/rancher/rke2
      cat >/etc/rancher/rke2/config.yaml <<EOF
      write-kubeconfig-mode: "0644"
      tls-san:
        - ${VM_IP}
        - ${VM_HOSTNAME}
      disable:
        - rke2-snapshot-controller
        - rke2-snapshot-controller-crd
        - rke2-snapshot-validation-webhook
        - rke2-metrics-server
        - rke2-ingress-nginx
      EOF

      echo "[rke2] installing rke2-server (pinned: ${RKE2_VERSION}) - idempotent"
      if [ ! -x /usr/local/bin/rke2 ]; then
        curl -sfL https://get.rke2.io | \
          INSTALL_RKE2_VERSION="${RKE2_VERSION}" \
          INSTALL_RKE2_TYPE=server \
          sh -
      else
        echo '[rke2] already installed, skipping'
      fi

      echo '[rke2] enabling and starting rke2-server'
      systemctl enable --now rke2-server

      echo '[rke2] waiting for node Ready (up to 15 min; image pulls dominate on first boot)'
      KCTL=/var/lib/rancher/rke2/bin/kubectl
      KCFG=/etc/rancher/rke2/rke2.yaml
      ready=false
      for i in $(seq 1 180); do
        if [ -f "$KCFG" ] && ${KCTL} --kubeconfig=$KCFG get nodes 2>/dev/null | grep -q ' Ready '; then
          echo "[rke2] node Ready after $((i*5))s"
          ready=true
          break
        fi
        # Print progress every minute so the log shows life during the long pull
        if [ $((i % 12)) -eq 0 ]; then
          echo "[rke2] still waiting for node Ready ($((i*5))s / 900s)"
        fi
        sleep 5
      done
      if [ "$ready" != "true" ]; then
        echo '[rke2] node did NOT reach Ready in 15 min - check journalctl -u rke2-server'
        echo '[rke2] last 60 lines of rke2-server logs:'
        journalctl -u rke2-server --no-pager -n 60 || true
        exit 1
      fi

      echo '[rke2] exporting kubeconfig with VM IP to /vagrant/kubeconfig'
      sed "s|server: https://127.0.0.1:6443|server: https://${VM_IP}:6443|" \
        /etc/rancher/rke2/rke2.yaml > /vagrant/kubeconfig
      chmod 644 /vagrant/kubeconfig
      echo '[rke2] kubeconfig written - use $env:KUBECONFIG="$(pwd)\\kubeconfig" on the host'
    SHELL
end