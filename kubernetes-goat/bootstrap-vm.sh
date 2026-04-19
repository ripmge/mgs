#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_ENV="/usr/local/lib/kubernetes-goat/bootstrap.env"
BOOTSTRAP_LOG="/var/log/kubernetes-goat-bootstrap.log"
ACCESS_LOG="/var/log/kubernetes-goat-access.log"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

if [[ ! -f "${BOOTSTRAP_ENV}" ]]; then
  echo "[!] Missing bootstrap env: ${BOOTSTRAP_ENV}" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${BOOTSTRAP_ENV}"

MARKER_DIR="${GOAT_STATE_DIR}/markers"
PREREQ_MARKER="${MARKER_DIR}/prereqs.done"
DOCKER_MARKER="${MARKER_DIR}/docker.done"
K3S_MARKER="${MARKER_DIR}/k3s.done"
HELM_MARKER="${MARKER_DIR}/helm.done"
GOAT_MARKER="${MARKER_DIR}/goat.done"

mkdir -p "${MARKER_DIR}" "${GOAT_INSTALL_DIR}"
touch "${BOOTSTRAP_LOG}" "${ACCESS_LOG}"

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

serial_log() {
  local message="$1"
  echo "${message}" >/dev/ttyS0 2>/dev/null || true
}

log() {
  local message="$1"
  echo "[*] ${message}"
  serial_log "kubernetes-goat bootstrap: ${message}"
}

fail() {
  local rc="$1"
  serial_log "kubernetes-goat bootstrap: FAILED rc=${rc}"
  exit "${rc}"
}

trap 'fail $?' ERR

mark_done() {
  local marker="$1"
  touch "${marker}"
}

install_prereqs() {
  if [[ -f "${PREREQ_MARKER}" ]]; then
    log "Guest prerequisites already installed"
    return
  fi

  log "Installing guest prerequisite packages"
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    socat \
    wget
  mark_done "${PREREQ_MARKER}"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && [[ -f "${DOCKER_MARKER}" ]]; then
    log "Docker already installed"
    return
  fi

  log "Installing Docker from ${DOCKER_INSTALL_SCRIPT_URL}"
  curl -fsSL "${DOCKER_INSTALL_SCRIPT_URL}" -o /tmp/install-docker.sh
  chmod 0755 /tmp/install-docker.sh
  /tmp/install-docker.sh

  install -d -m 0755 /etc/docker
  cat >/etc/docker/daemon.json <<'EOF'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"]
}
EOF

  cat >/etc/sysctl.d/99-kubernetes-goat.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

  sysctl --system >/dev/null
  systemctl daemon-reload
  systemctl enable docker
  systemctl restart docker
  mark_done "${DOCKER_MARKER}"
}

install_k3s() {
  if [[ -f "${K3S_MARKER}" ]] && systemctl is-active --quiet k3s; then
    log "k3s already installed"
    return
  fi

  log "Installing k3s ${K3S_VERSION} with Docker runtime"
  curl -sfL https://get.k3s.io -o /tmp/install-k3s.sh
  chmod 0755 /tmp/install-k3s.sh

  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server --docker --disable traefik --disable servicelb --disable-network-policy --kube-apiserver-arg=allow-privileged=true --write-kubeconfig-mode 644" \
    /tmp/install-k3s.sh

  mkdir -p /root/.kube
  cp -f "${KUBECONFIG_PATH}" /root/.kube/config
  chmod 0600 /root/.kube/config
  mark_done "${K3S_MARKER}"
}

wait_for_k3s() {
  log "Waiting for k3s node readiness"
  export KUBECONFIG="${KUBECONFIG_PATH}"

  local attempt
  for attempt in $(seq 1 60); do
    if kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"; then
      return
    fi
    sleep 5
  done

  echo "[!] Timed out waiting for k3s" >&2
  return 1
}

install_helm() {
  if command -v helm >/dev/null 2>&1 && [[ -f "${HELM_MARKER}" ]]; then
    log "Helm already installed"
    return
  fi

  log "Installing Helm ${HELM_VERSION}"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3
  chmod 0755 /tmp/get-helm-3
  DESIRED_VERSION="${HELM_VERSION}" /tmp/get-helm-3
  mark_done "${HELM_MARKER}"
}

sync_goat_repo() {
  log "Syncing Kubernetes Goat repository at ${GOAT_REPO_VERSION}"
  if [[ -d "${GOAT_INSTALL_DIR}/.git" ]]; then
    git -C "${GOAT_INSTALL_DIR}" fetch --tags --force origin
    git -C "${GOAT_INSTALL_DIR}" checkout --force "${GOAT_REPO_VERSION}"
    git -C "${GOAT_INSTALL_DIR}" reset --hard "origin/$(git -C "${GOAT_INSTALL_DIR}" rev-parse --abbrev-ref HEAD)" 2>/dev/null || true
  else
    rm -rf "${GOAT_INSTALL_DIR}"
    git clone --branch "${GOAT_REPO_VERSION}" --depth 1 "${GOAT_REPO_URL}" "${GOAT_INSTALL_DIR}"
  fi

  chmod 0755 \
    "${GOAT_INSTALL_DIR}/setup-kubernetes-goat.sh" \
    "${GOAT_INSTALL_DIR}/access-kubernetes-goat.sh" \
    "${GOAT_INSTALL_DIR}/teardown-kubernetes-goat.sh"
}

deploy_goat() {
  export KUBECONFIG="${KUBECONFIG_PATH}"

  if [[ -f "${GOAT_MARKER}" ]]; then
    log "Kubernetes Goat already deployed"
    return
  fi

  sync_goat_repo
  log "Deploying Kubernetes Goat"
  (
    cd "${GOAT_INSTALL_DIR}"
    bash ./setup-kubernetes-goat.sh
  )

  mark_done "${GOAT_MARKER}"
}

wait_for_goat_pods() {
  export KUBECONFIG="${KUBECONFIG_PATH}"
  log "Waiting for Kubernetes Goat pods"

  local attempt pending
  for attempt in $(seq 1 60); do
    pending="$(
      kubectl get pods -A --no-headers 2>/dev/null \
        | awk '$4 != "Running" && $4 != "Completed" {count++} END {print count+0}'
    )"
    if [[ "${pending}" == "0" ]]; then
      return
    fi
    sleep 10
  done

  echo "[!] Timed out waiting for Kubernetes Goat pods" >&2
  return 1
}

install_access_service() {
  cat >/usr/local/lib/kubernetes-goat/start-access.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export HOME=/root
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
ACCESS_LOG=/var/log/kubernetes-goat-access.log

touch "${ACCESS_LOG}"

start_port_forward() {
  local namespace="$1"
  local selector="$2"
  local local_port="$3"
  local remote_port="$4"
  local pod_name

  pod_name="$(
    kubectl get pods --namespace "${namespace}" -l "${selector}" \
      -o jsonpath="{.items[0].metadata.name}"
  )"

  kubectl --namespace "${namespace}" port-forward "${pod_name}" --address 0.0.0.0 \
    "${local_port}:${remote_port}" >>"${ACCESS_LOG}" 2>&1 &
}

pkill -f "kubectl.*port-forward" 2>/dev/null || true

start_port_forward default "app=build-code" 1230 3000
start_port_forward default "app=health-check" 1231 80
start_port_forward default "app=internal-proxy" 1232 3000
start_port_forward default "app=system-monitor" 1233 8080
start_port_forward default "app=kubernetes-goat-home" 1234 80
start_port_forward default "app=poor-registry" 1235 5000
start_port_forward big-monolith "app=hunger-check" 1236 8080

wait
EOF
  chmod 0755 /usr/local/lib/kubernetes-goat/start-access.sh

  cat >/etc/systemd/system/kubernetes-goat-access.service <<'EOF'
[Unit]
Description=Expose Kubernetes Goat port forwards
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 15
ExecStart=/usr/local/lib/kubernetes-goat/start-access.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable kubernetes-goat-access.service
  systemctl restart kubernetes-goat-access.service
}

main() {
  log "Starting guest bootstrap"
  install_prereqs
  install_docker
  install_k3s
  wait_for_k3s
  install_helm
  deploy_goat
  wait_for_goat_pods
  install_access_service
  serial_log "kubernetes-goat bootstrap: DONE"
  log "Bootstrap complete"
}

main "$@"
