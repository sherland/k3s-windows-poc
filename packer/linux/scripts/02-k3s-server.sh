#!/usr/bin/env bash
# =============================================================================
# packer/linux/scripts/02-k3s-server.sh
# Install k3s as a server (control-plane + Linux worker node).
# Environment variables injected by Packer:
#   K3S_VERSION  — e.g. v1.32.5+k3s1
# =============================================================================

set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.32.5+k3s1}"
INSTALL_TIMEOUT=300   # seconds

echo "==> 02-k3s-server: Installing k3s ${K3S_VERSION}"

# Determine flannel backend from the FLANNEL_BACKEND env var (set by Bootstrap-ControlPlane.ps1).
# host-gw (default): L2 routing, no VXLAN — required for Windows workers on the same L2 subnet.
# none: disable k3s embedded flannel — used when an external CNI (Cilium) manages networking.
if [ "${FLANNEL_BACKEND:-host-gw}" = "none" ]; then
    _FLANNEL_FLAGS="--flannel-backend=none --disable-network-policy"
else
    _FLANNEL_FLAGS="--flannel-backend=host-gw"
fi

curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_EXEC="server --disable traefik ${_FLANNEL_FLAGS} --node-label kubernetes.io/os=linux --write-kubeconfig-mode 0644" \
    sh -

echo "==> 02-k3s-server: Waiting for k3s to become ready (timeout ${INSTALL_TIMEOUT}s)..."
deadline=$((SECONDS + INSTALL_TIMEOUT))
while true; do
    status=$(systemctl is-active k3s 2>/dev/null || echo 'inactive')
    if [ "$status" = 'active' ]; then
        break
    fi
    if [ $SECONDS -ge $deadline ]; then
        echo "ERROR: k3s did not become active within ${INSTALL_TIMEOUT}s"
        systemctl status k3s --no-pager || true
        journalctl -u k3s --no-pager -n 50 || true
        exit 1
    fi
    sleep 5
done

echo "==> 02-k3s-server: Waiting for node to report Ready..."
deadline=$((SECONDS + INSTALL_TIMEOUT))
while true; do
    ready=$(k3s kubectl get nodes --no-headers 2>/dev/null | grep -c 'Ready' || echo '0')
    if [ "$ready" -ge 1 ]; then
        break
    fi
    if [ $SECONDS -ge $deadline ]; then
        echo "ERROR: Node did not report Ready within ${INSTALL_TIMEOUT}s"
        k3s kubectl get nodes 2>/dev/null || true
        exit 1
    fi
    sleep 5
done

echo "==> 02-k3s-server: k3s server is Ready"
k3s kubectl get nodes

echo "==> 02-k3s-server: Enabling k3s on boot"
systemctl enable k3s

# ---------------------------------------------------------------------------
# Prepare Kubernetes resources needed by Windows worker nodes
# ---------------------------------------------------------------------------

echo "==> 02-k3s-server: Creating kube-flannel namespace, RBAC, and ConfigMap"
# Windows workers run their own flanneld.exe as a Windows service (host-gw mode).
# They need:
#   - kube-flannel namespace
#   - flannel ServiceAccount + RBAC to read/patch Node objects
#   - kube-flannel-cfg ConfigMap with net-conf.json (must match k3s flannel config)
#   - A long-lived ServiceAccount token for flanneld.exe to authenticate
k3s kubectl apply -f - << 'FLANNEL_EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: kube-flannel
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flannel
  namespace: kube-flannel
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: flannel
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get]
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [nodes/status]
    verbs: [patch]
  - apiGroups: ["networking.k8s.io"]
    resources: [clustercidrs]
    verbs: [list, watch]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
  - kind: ServiceAccount
    name: flannel
    namespace: kube-flannel
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": { "portMappings": true }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.42.0.0/16",
      "Backend": {
        "Type": "host-gw"
      }
    }
FLANNEL_EOF

# Create a long-lived token secret for the flannel ServiceAccount.
# Windows flanneld.exe uses this to authenticate with the k8s API.
k3s kubectl apply -f - << 'TOKEN_EOF'
apiVersion: v1
kind: Secret
metadata:
  name: flannel-token
  namespace: kube-flannel
  annotations:
    kubernetes.io/service-account.name: flannel
type: kubernetes.io/service-account-token
TOKEN_EOF

# Wait for the token controller to populate the secret
echo "==> 02-k3s-server: Waiting for flannel ServiceAccount token..."
for i in $(seq 1 20); do
    TOKEN=$(k3s kubectl get secret flannel-token -n kube-flannel \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        break
    fi
    sleep 3
done
if [ -z "$TOKEN" ]; then
    echo "ERROR: flannel-token not populated after 60s"
    exit 1
fi

# Write a kubeconfig for Windows flanneld.exe
# (uses flannel ServiceAccount token — read-only on nodes, not cluster-admin)
NODE_IP=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1); exit}')
FLANNEL_CA=$(k3s kubectl get secret flannel-token -n kube-flannel \
    -o jsonpath='{.data.ca\.crt}')
cat > /var/lib/rancher/k3s/server/flannel-kubeconfig.yaml << KUBECONF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${FLANNEL_CA}
    server: https://${NODE_IP}:6443
  name: k3s
contexts:
- context:
    cluster: k3s
    user: flannel
  name: k3s
current-context: k3s
users:
- name: flannel
  user:
    token: ${TOKEN}
KUBECONF
chmod 600 /var/lib/rancher/k3s/server/flannel-kubeconfig.yaml
echo "==> 02-k3s-server: flannel-kubeconfig.yaml written"

echo "==> 02-k3s-server: Creating kubelet CSR auto-approve RBAC for Windows nodes"
# Allow nodes in the system:bootstrappers group to have their CSRs auto-approved.
# Windows kubelet uses --bootstrap-kubeconfig for initial cert request.
# (Also enables cert rotation for all nodes.)
k3s kubectl apply -f - << 'RBAC_EOF'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeadm:node-autoapprove-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:bootstrappers:kubeadm:default-node-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeadm:node-autoapprove-certificate-rotation
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:nodes
RBAC_EOF

echo "==> 02-k3s-server: Done"
