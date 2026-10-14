#!/usr/bin/env bash
# CKA-style administration drills on a 3-node kind cluster. Each drill does the task, then checks the result.
# Usage: kind create cluster --config kind-cluster.yaml && ./run-drills.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1

CLUSTER=hybrid
CP=$CLUSTER-control-plane
W1=$CLUSTER-worker
W2=$CLUSTER-worker2
failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "::error title=k8s-admin drills::$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }
retry() { local n=$1; shift; for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 3; done; return 1; }
section() { echo; echo "== $1"; }
can() { [ "$(kubectl auth can-i "$@" 2>/dev/null)" = "yes" ]; }

kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null

# ---------------------------------------------------------------------------
section "1. RBAC: service accounts, roles and bindings"
kubectl apply -f manifests/rbac.yaml >/dev/null
SA=system:serviceaccount:team-a:viewer
check "viewer can list pods in team-a" can list pods -n team-a --as=$SA
check "viewer can read pod logs in team-a" can get pods/log -n team-a --as=$SA
check "viewer cannot delete pods" not can delete pods -n team-a --as=$SA
check "viewer cannot see other namespaces" not can list pods -n default --as=$SA
check "ops service account can list nodes cluster-wide" can list nodes --as=system:serviceaccount:kube-system:ops
check "ops service account cannot delete nodes" not can delete nodes --as=system:serviceaccount:kube-system:ops

# ---------------------------------------------------------------------------
section "2. A new human user through a certificate signing request"
work=$(mktemp -d)
openssl req -new -newkey rsa:2048 -nodes -keyout "$work/jane.key" -subj "/CN=jane/O=developers" -out "$work/jane.csr" 2>/dev/null
kubectl delete csr jane --ignore-not-found >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: jane
spec:
  request: $(base64 -w0 < "$work/jane.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages: [client auth]
EOF
kubectl certificate approve jane >/dev/null
cert_issued() { [ -n "$(kubectl get csr jane -o jsonpath='{.status.certificate}')" ]; }
check "CSR for jane approved and signed by the cluster CA" retry 10 cert_issued
kubectl get csr jane -o jsonpath='{.status.certificate}' | base64 -d > "$work/jane.crt"
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$work/ca.crt"
JANE="$work/jane.kubeconfig"
kubectl --kubeconfig "$JANE" config set-cluster $CLUSTER --server="$server" --certificate-authority="$work/ca.crt" --embed-certs >/dev/null
kubectl --kubeconfig "$JANE" config set-credentials jane --client-certificate="$work/jane.crt" --client-key="$work/jane.key" --embed-certs >/dev/null
kubectl --kubeconfig "$JANE" config set-context jane --cluster=$CLUSTER --user=jane --namespace=team-a >/dev/null
kubectl --kubeconfig "$JANE" config use-context jane >/dev/null
whoami=$(kubectl --kubeconfig "$JANE" auth whoami -o jsonpath='{.status.userInfo.username}/{.status.userInfo.groups[0]}' 2>/dev/null)
check "jane authenticates with her certificate as jane/developers ($whoami)" test "$whoami" = "jane/developers"
jane_deploy() { kubectl --kubeconfig "$JANE" -n team-a create deployment hello --image=registry.k8s.io/pause:3.10 >/dev/null; }
check "jane can create a deployment in team-a (developers group binding)" jane_deploy
jane_secrets() { kubectl --kubeconfig "$JANE" -n team-a get secrets >/dev/null 2>&1; }
check "jane cannot read secrets" not jane_secrets

# ---------------------------------------------------------------------------
section "3. Scheduling: taints, tolerations and node affinity"
kubectl label node "$W2" tier=db --overwrite >/dev/null
kubectl taint node "$W2" dedicated=db:NoSchedule --overwrite >/dev/null
kubectl apply -f manifests/scheduling.yaml >/dev/null
kubectl rollout status deploy/db-tier --timeout=120s >/dev/null
kubectl rollout status deploy/general --timeout=120s >/dev/null
nodes_of() { kubectl get pods -l "app=$1" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | tr '\n' ' '; }
check "db-tier runs only on the dedicated node ($(nodes_of db-tier))" test "$(nodes_of db-tier)" = "$W2 "
check "general workloads stay off the tainted node ($(nodes_of general))" not grep -q "$W2" <<<"$(nodes_of general)"
kubectl delete -f manifests/scheduling.yaml --wait=false >/dev/null
kubectl taint node "$W2" dedicated=db:NoSchedule- >/dev/null

# ---------------------------------------------------------------------------
section "4. Node maintenance: cordon and drain with a PodDisruptionBudget"
kubectl apply -f manifests/maintenance.yaml >/dev/null
kubectl rollout status deploy/web --timeout=180s >/dev/null
if ! out=$(kubectl drain "$W1" --ignore-daemonsets --delete-emptydir-data --timeout=180s 2>&1); then
  echo "::error title=drain::$(echo "$out" | tail -8 | cut -c1-250 | sed ':a;N;$!ba;s/\n/%0A/g')"
fi
check "drained node is unschedulable" test "$(kubectl get node "$W1" -o jsonpath='{.spec.unschedulable}')" = "true"
off_w1() { ! kubectl get pods -l app=web --field-selector=status.phase!=Succeeded -o jsonpath='{.items[*].spec.nodeName}' | grep -q "$W1"; }
check "no web pods left on the drained node" retry 20 off_w1
web_ready() { [ "$(kubectl get deploy web -o jsonpath='{.status.readyReplicas}')" = "3" ]; }
check "all 3 web pods are running elsewhere" retry 30 web_ready
kubectl uncordon "$W1" >/dev/null
check "node is back in service after uncordon" test -z "$(kubectl get node "$W1" -o jsonpath='{.spec.unschedulable}')"

# ---------------------------------------------------------------------------
section "5. NetworkPolicy: default deny, allow only the frontend"
kubectl apply -f manifests/network-policy.yaml >/dev/null
kubectl -n shop rollout status deploy/api --timeout=120s >/dev/null
probe() { # probe <label> : can a pod with app=<label> reach the api?
  kubectl -n shop run "probe-$1-$RANDOM" --rm -i --restart=Never --labels="app=$1" --image=curlimages/curl:8.10.1 \
    --command -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://api >/tmp/probe.out 2>/dev/null
  grep -q '^200' /tmp/probe.out
}
check "frontend pod reaches the api" retry 5 probe frontend
check "any other pod is blocked by the default-deny policy" not probe intruder

# ---------------------------------------------------------------------------
section "6. Troubleshooting a broken rollout"
kubectl apply -f manifests/broken-deployment.yaml >/dev/null
pull_error() { kubectl get pods -l app=checkout -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' | grep -Eq 'ErrImagePull|ImagePullBackOff'; }
check "diagnosed: pods are stuck on an image pull error" retry 20 pull_error
echo "      events: $(kubectl get events --field-selector reason=Failed -o jsonpath='{.items[-1:].message}' | cut -c1-120)"
kubectl set image deploy/checkout checkout=nginx:1.27.2 >/dev/null
check "fixed: rollout completes after correcting the image" kubectl rollout status deploy/checkout --timeout=180s
kubectl set image deploy/checkout checkout=nginx:1.27.2-doesnotexist >/dev/null
sleep 5
kubectl rollout undo deploy/checkout >/dev/null
check "a second bad release is reverted with rollout undo" kubectl rollout status deploy/checkout --timeout=180s
check "the reverted deployment runs the good image" test "$(kubectl get deploy checkout -o jsonpath='{.spec.template.spec.containers[0].image}')" = "nginx:1.27.2"

# ---------------------------------------------------------------------------
section "7. etcd backup and restore (last: it rolls the cluster back to the snapshot)"
ETCD_POD=etcd-$CP
etcdctl() {
  kubectl -n kube-system exec "$ETCD_POD" -- etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key "$@"
}
kubectl create configmap backup-marker --from-literal=taken="$(date -u +%FT%TZ)" >/dev/null
check "snapshot saved" etcdctl snapshot save /var/lib/etcd/backup.db
echo "      $(etcdctl snapshot status /var/lib/etcd/backup.db -w table 2>/dev/null | sed -n 4p)"
kubectl delete configmap backup-marker >/dev/null
check "marker deleted after the snapshot (simulated accident)" not kubectl get configmap backup-marker
PEER=$(docker exec "$CP" sed -n 's/.*--initial-advertise-peer-urls=//p' /etc/kubernetes/manifests/etcd.yaml)
echo "      peer URL: $PEER"
# the etcd image that ships with Kubernetes has etcdctl but not etcdutl, so restore with etcdctl
if ! out=$(etcdctl snapshot restore /var/lib/etcd/backup.db \
    --data-dir /var/lib/etcd/restored --name "$CP" --initial-cluster "$CP=$PEER" \
    --initial-advertise-peer-urls "$PEER" 2>&1); then
  echo "::error title=etcdutl restore::$(echo "$out" | tail -8 | cut -c1-250 | sed ':a;N;$!ba;s/\n/%0A/g')"
fi
restored_ok() { docker exec "$CP" test -d /var/lib/etcd/restored/member; }
check "snapshot restored into a new data directory" restored_ok
if ! restored_ok; then
  echo "Restore failed: leaving etcd on its original data so the cluster is not wiped."
  echo; echo "$((failures + 1)) drill check(s) failed."; exit $((failures + 1))
fi
# point the static etcd pod at the restored data; the kubelet restarts it
docker exec "$CP" sed -i 's#--data-dir=/var/lib/etcd$#--data-dir=/var/lib/etcd/restored#' /etc/kubernetes/manifests/etcd.yaml
sleep 20
api_back() { kubectl get --raw /readyz >/dev/null 2>&1; }
check "API server is healthy again on the restored etcd" retry 60 api_back
marker_back() { kubectl get configmap backup-marker >/dev/null 2>&1; }
check "the deleted object is back after the restore" retry 20 marker_back

echo
if [ "$failures" -eq 0 ]; then echo "All drills passed."; else echo "$failures drill check(s) failed."; fi
exit "$failures"
