## Problem: Multus silently skips secondary network attachments due to missing CNI plugin binaries

### What is happening

Multus CNI (thick-plugin mode) is installed and running. Pods have the correct
k8s.v1.cni.cncf.io/networks annotation requesting secondary network interfaces
via NetworkAttachmentDefinition resources that specify type: macvlan with static
or host-local IPAM. The NADs exist in the cluster and Multus has RBAC permission
to read them.

When a pod is created, Multus processes the ADD CNI request, attaches the primary
interface (eth0) via the default CNI (flannel/cbr0), then silently exits without
attaching any secondary interfaces and returns err: <nil>. No Warning events are
emitted on the pod. The k8s.v1.cni.cncf.io/network-status annotation on the pod
only contains the primary interface.

### Root cause

The macvlan and static binaries from the containernetworking/plugins package
(https://github.com/containernetworking/plugins) are NOT present on the nodes.
The only CNI binaries available are those bundled with k3s itself: bandwidth,
bridge, cni, firewall, flannel, host-local, loopback, multus-shim, portmap.

When Multus attempts to invoke the macvlan plugin it cannot find the executable.
In thick-plugin mode (v4.x), this failure is swallowed silently -- Multus does
not emit a pod Warning event and does not fail the CNI ADD call. The result is a
Running pod with only the default interface.

### Minimum reproduction steps

Prerequisites: A Kubernetes cluster with Multus CNI installed (thick-plugin, v4.x),
where cni-plugins has NOT been installed on the nodes.

--- 1. Verify the missing binary (the bug) ---

# On each node, confirm macvlan is absent
ls /var/lib/rancher/k3s/data/cni/   # k3s clusters
# or
ls /opt/cni/bin/                     # standard clusters
# Expected: macvlan is NOT listed

--- 2. Create a minimal NAD and pod to reproduce ---

# nad.yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: test-macvlan
  namespace: default
spec:
  config: |-
    {
      "cniVersion": "0.3.0",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": { "type": "host-local", "subnet": "192.168.100.0/24" }
    }
---
# pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-multus-pod
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/networks: test-macvlan
spec:
  containers:
  - name: test
    image: busybox
    command: ["sleep", "3600"]

kubectl apply -f nad.yaml -f pod.yaml
kubectl wait --for=condition=Ready pod/test-multus-pod --timeout=60s

--- 3. Observe the bug -- only eth0 in network-status, no warnings ---

kubectl get pod test-multus-pod -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | python3 -m json.tool
# Bug: only the default interface appears, no secondary, no error

kubectl get events --field-selector involvedObject.name=test-multus-pod
# Bug: only Normal events, no Warning about macvlan failure

--- 4. Fix -- install cni-plugins on every node ---

# Run on each node (adjust version as needed)
CNI_VERSION=v1.5.1
curl -LO https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz
sudo mkdir -p /opt/cni/bin
sudo tar -xzf cni-plugins-linux-amd64-${CNI_VERSION}.tgz -C /opt/cni/bin/
ls /opt/cni/bin/macvlan   # must exist

--- 5. Verify the fix -- delete and recreate the pod ---

kubectl delete pod test-multus-pod
kubectl apply -f pod.yaml
kubectl wait --for=condition=Ready pod/test-multus-pod --timeout=60s

# Verify secondary interface was attached:
kubectl get pod test-multus-pod -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | python3 -m json.tool
# Fixed: two entries -- default eth0 + secondary net1 with IP from 192.168.100.0/24

kubectl get events --field-selector involvedObject.name=test-multus-pod | grep AddedInterface
# Fixed: two AddedInterface events

--- 6. Clean up ---

kubectl delete pod test-multus-pod
kubectl delete net-attach-def test-macvlan