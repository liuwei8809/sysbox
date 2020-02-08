#!/usr/bin/env bats

# Basic tests for deploying a K8s cluster inside system container nodes.
#
# NOTE: the "kind cluster up" test must execute before all others,
# as it brings up the K8s cluster. Similarly, the "kind cluster down"
# test must execute after all other tests.

load ../helpers/run
load ../helpers/docker
load ../helpers/k8s

export test_dir="/tmp/k8s-basic-test/"
export manifest_dir="tests/kind/manifests/"

function create_test_dir() {
  run mkdir -p "$test_dir"
  [ "$status" -eq 0 ]

  run rm -rf "$test_dir/*"
  [ "$status" -eq 0 ]
}

function remove_test_dir() {
  run rm -rf "$test_dir"
  [ "$status" -eq 0 ]
}

@test "kind cluster up" {

  create_test_dir

  local num_workers=2
  local kubeadm_join=$(k8s_cluster_setup $num_workers bridge)

  # store k8s cluster info so subsequent tests can use it
  echo $num_workers > "$test_dir/.k8s_num_workers"
  echo $kubeadm_join > "$test_dir/.kubeadm_join"
}

@test "kind pod" {

  cat > "$test_dir/basic-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx
EOF

  k8s_create_pod k8s-master "$test_dir/basic-pod.yaml"
  retry_run 20 2 "k8s_pod_ready k8s-master nginx"

  local pod_ip=$(k8s_pod_ip k8s-master nginx)

  docker exec k8s-master sh -c "curl -s $pod_ip | grep -q \"Welcome to nginx\""
  [ "$status" -eq 0 ]

  # cleanup
  k8s_del_pod k8s-master nginx
  rm "$test_dir/basic-pod.yaml"
}

@test "kind pod multi-container" {

  cat > "$test_dir/multi-cont-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: multi-cont
spec:
  containers:
  - name: alpine1
    image: alpine
    command: ["tail"]
    args: ["-f", "/dev/null"]
  - name: alpine2
    image: alpine
    command: ["tail"]
    args: ["-f", "/dev/null"]
EOF

  k8s_create_pod k8s-master "$test_dir/multi-cont-pod.yaml"
  retry_run 20 2 "k8s_pod_ready k8s-master multi-cont"

  # verify all containers in the pod are sharing the net ns

  docker exec k8s-master sh -c "kubectl exec multi-cont -c alpine1 readlink /proc/1/ns/net"
  [ "$status" -eq 0 ]
  alpine1_ns=$output

  docker exec k8s-master sh -c "kubectl exec multi-cont -c alpine2 readlink /proc/1/ns/net"
  [ "$status" -eq 0 ]
  alpine2_ns=$output

  [ "$alpine1_ns" == "$alpine2_ns" ]

  #cleanup

  k8s_del_pod k8s-master multi-cont
  rm "$test_dir/multi-cont-pod.yaml"
}

@test "kind deployment" {

  docker exec k8s-master sh -c "kubectl create deployment nginx --image=nginx:1.16-alpine"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_deployment_ready k8s-master default nginx"

  # scale up
  docker exec k8s-master sh -c "kubectl scale --replicas=3 deployment nginx"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_deployment_ready k8s-master default nginx"

  # rollout new nginx image
  docker exec k8s-master sh -c "kubectl set image deployment/nginx nginx=nginx:1.17-alpine --record"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_deployment_rollout_ready k8s-master default nginx"

  # scale down
  docker exec k8s-master sh -c "kubectl scale --replicas=1 deployment nginx"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_deployment_ready k8s-master default nginx"

  # cleanup
  docker exec k8s-master sh -c "kubectl delete deployments.apps nginx"
  [ "$status" -eq 0 ]
}

@test "kind service clusterIP" {

  docker exec k8s-master sh -c "kubectl create deployment nginx --image=nginx:1.17-alpine"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl scale --replicas=3 deployment nginx"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_deployment_ready k8s-master default nginx"

  # create a service and confirm it's there
  docker exec k8s-master sh -c "kubectl expose deployment/nginx --port 80"
  [ "$status" -eq 0 ]

  local svc_ip=$(k8s_svc_ip k8s-master default nginx)

  docker exec k8s-master sh -c "curl -s $svc_ip | grep -q \"Welcome to nginx\""
  [ "$status" -eq 0 ]

  # launch an pod in the same k8s namespace and verify it can access the service
  cat > /tmp/alpine-sleep.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: alpine-sleep
spec:
  containers:
  - name: alpine
    image: alpine
    args:
    - sleep
    - "1000000"
EOF

  k8s_create_pod k8s-master /tmp/alpine-sleep.yaml
  retry_run 10 2 "k8s_pod_ready k8s-master alpine-sleep"

  docker exec k8s-master sh -c "kubectl exec alpine-sleep -- sh -c \"apk add curl\""
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c 'kubectl exec alpine-sleep -- sh -c "curl -s \$NGINX_SERVICE_HOST" | grep -q "Welcome to nginx"'
  [ "$status" -eq 0 ]

  # verify the kube-proxy is using iptables (does so by default)
  k8s_check_proxy_mode k8s-master iptables

  # verify k8s has programmed iptables inside the sys container net ns
  docker exec k8s-master sh -c "iptables -L | grep -q KUBE"
  [ "$status" -eq 0 ]

  # verify no k8s iptable chains are seen outside the sys container net ns
  iptables -L | grep -qv KUBE

  # cleanup
  k8s_del_pod k8s-master alpine-sleep

  docker exec k8s-master sh -c "kubectl delete svc nginx"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl delete deployments.apps nginx"
  [ "$status" -eq 0 ]

  rm /tmp/alpine-sleep.yaml
}

@test "kind service nodePort" {

  local num_workers=$(cat "$test_dir/.k8s_num_workers")

  docker exec k8s-master sh -c "kubectl create deployment nginx --image=nginx:1.17-alpine"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_deployment_ready k8s-master default nginx"

  # create a nodePort service
  docker exec k8s-master sh -c "kubectl expose deployment/nginx --port 80 --type NodePort"
  [ "$status" -eq 0 ]

  # get the node port for the service
  docker exec k8s-master sh -c "kubectl get svc nginx -o json | jq .spec.ports[0].nodePort"
  [ "$status" -eq 0 ]
  svc_port=$output

  # verify the service is exposed on all nodes of the cluster
  node_ip=$(k8s_node_ip k8s-master)
  curl -s $node_ip:$svc_port | grep "Welcome to nginx"

  for i in `seq 0 $(( $num_workers - 1 ))`; do
    local worker=k8s-worker-$i
    node_ip=$(k8s_node_ip $worker)
    curl -s $node_ip:$svc_port | grep -q "Welcome to nginx"
  done

  # verify we can access the service from within a pod in the cluster
  cat > /tmp/alpine-sleep.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: alpine-sleep
spec:
  containers:
  - name: alpine
    image: alpine
    args:
    - sleep
    - "1000000"
EOF

  k8s_create_pod k8s-master /tmp/alpine-sleep.yaml
  retry_run 10 2 "k8s_pod_ready k8s-master alpine-sleep"

  docker exec k8s-master sh -c "kubectl exec alpine-sleep -- sh -c \"apk add curl\""
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c 'kubectl exec alpine-sleep -- sh -c "curl -s \$NGINX_SERVICE_HOST" | grep -q "Welcome to nginx"'
  [ "$status" -eq 0 ]

  # cleanup
  k8s_del_pod k8s-master alpine-sleep

  docker exec k8s-master sh -c "kubectl delete svc nginx"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl delete deployments.apps nginx"
  [ "$status" -eq 0 ]

  rm /tmp/alpine-sleep.yaml
}

@test "kind DNS clusterIP" {

  # launch a deployment with an associated service

  docker exec k8s-master sh -c "kubectl create deployment nginx --image=nginx:1.17-alpine"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl expose deployment/nginx --port 80"
  [ "$status" -eq 0 ]

  # launch a pod in the same k8s namespace
  cat > /tmp/alpine-sleep.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: alpine-sleep
spec:
  containers:
  - name: alpine
    image: alpine
    args:
    - sleep
    - "1000000"
EOF

  k8s_create_pod k8s-master /tmp/alpine-sleep.yaml
  retry_run 10 2 "k8s_pod_ready k8s-master alpine-sleep"

  # find the cluster's DNS IP address
  docker exec k8s-master sh -c "kubectl get services --all-namespaces -o wide | grep kube-dns | awk '{print \$4}'"
  [ "$status" -eq 0 ]
  local dns_ip=$output

  # verify the pod has the cluster DNS server in its /etc/resolv.conf
  docker exec k8s-master sh -c "kubectl exec alpine-sleep -- sh -c \"cat /etc/resolv.conf\" | grep nameserver | awk '{print \$2}'"
  [ "$status" -eq 0 ]
  [ "$output" == "$dns_ip" ]

  # verify the pod can query the DNS server
  docker exec k8s-master sh -c "kubectl exec alpine-sleep -- sh -c \"nslookup nginx.default.svc.cluster.local\""
  [ "$status" -eq 0 ]

  local nslookup=$output
  dns_server=$(echo "$nslookup" | grep "Server" | awk '{print $2}')
  svc_name=$(echo "$nslookup" | grep "Name" | awk '{print $2}')
  svc_ip=$(echo "$nslookup" | grep -A 1 "Name" | grep "Address" | awk '{print $2}')

  [ "$dns_server" == "$dns_ip" ]

  docker exec k8s-master sh -c "kubectl exec alpine-sleep -- sh -c \"nslookup google.com\""
  [ "$status" -eq 0 ]

  # verify DNS resolution works
  docker exec k8s-master sh -c "kubectl exec alpine-sleep -- sh -c \"apk add curl\""
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl exec alpine-sleep -- sh -c \"curl -s nginx.default.svc.cluster.local\" | grep -q \"Welcome to nginx\""
  [ "$status" -eq 0 ]

  # query the DNS server from the K8s node itself (note that since the
  # node has its own DNS services, we have to point to the cluster's
  # DNS explicitly).

  docker exec k8s-master sh -c "nslookup nginx.default.svc.cluster.local $dns_ip"
  [ "$status" -eq 0 ]

  # if we repeat the above but without pointing to the cluster's DNS
  # server, it should fail because the node's DNS server's can't see
  # the nginx server (i.e., the nginx service lives inside the
  # cluster)

  docker exec k8s-master sh -c "nslookup nginx.default.svc.cluster.local"
  [ "$status" -eq 1 ]

  # cleanup

  k8s_del_pod k8s-master alpine-sleep

  docker exec k8s-master sh -c "kubectl delete svc nginx"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl delete deployments.apps nginx"
  [ "$status" -eq 0 ]

  rm /tmp/alpine-sleep.yaml
}

@test "kind ingress" {

  # Based on:
  # https://docs.traefik.io/v1.7/user-guide/kubernetes/

  # the test will be modifying /etc/hosts in the test container;
  # create a backup so we can revert it after the test finishes.
  cp /etc/hosts /etc/hosts.orig

  # deploy the ingress controller (traefik) and associated services and ingress rules
  docker cp $manifest_dir/traefik.yaml k8s-master:/root/traefik.yaml
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl apply -f /root/traefik.yaml"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_daemonset_ready k8s-master kube-system traefik-ingress-controller"

  # setup the ingress hostname in /etc/hosts
  local node_ip=$(k8s_node_ip k8s-worker-0)
  echo "$node_ip traefik-ui.nestykube" >> /etc/hosts

  # verify ingress to traefik-ui works
  sleep 20

  wget traefik-ui.nestykube -O $test_dir/index.html
  grep Traefik $test_dir/index.html
  rm $test_dir/index.html

  # deploy nginx and create a service for it
  docker exec k8s-master sh -c "kubectl create deployment nginx --image=nginx:1.16-alpine"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl scale --replicas=3 deployment nginx"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl expose deployment/nginx --port 80"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_deployment_ready k8s-master default nginx"

  # create an ingress rule for the nginx service
cat > "$test_dir/nginx-ing.yaml" <<EOF
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: nginx
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
  - host: nginx.nestykube
    http:
      paths:
      - path: /
        backend:
          serviceName: nginx
          servicePort: 80
EOF

  # apply the ingress rule
  docker cp $test_dir/nginx-ing.yaml k8s-master:/root/nginx-ing.yaml
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl apply -f /root/nginx-ing.yaml"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_daemonset_ready k8s-master kube-system traefik-ingress-controller"

  # setup the ingress hostname in /etc/hosts
  local node_ip=$(k8s_node_ip k8s-worker-1)
  echo "$node_ip nginx.nestykube" >> /etc/hosts

  # verify ingress to nginx works
  sleep 3

  wget nginx.nestykube -O $test_dir/index.html
  grep "Welcome to nginx" $test_dir/index.html
  rm $test_dir/index.html

  # cleanup
  docker exec k8s-master sh -c "kubectl delete ing nginx"
  [ "$status" -eq 0 ]
  docker exec k8s-master sh -c "kubectl delete svc nginx"
  [ "$status" -eq 0 ]
  docker exec k8s-master sh -c "kubectl delete deployment nginx"
  [ "$status" -eq 0 ]
  docker exec k8s-master sh -c "kubectl delete -f /root/traefik.yaml"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "rm /root/nginx-ing.yaml && rm /root/traefik.yaml"
  [ "$status" -eq 0 ]

  rm $test_dir/nginx-ing.yaml
  cp /etc/hosts.orig /etc/hosts
}

# Verifies that pods get re-scheduled when a K8s node goes down
@test "node down" {

  skip "FAILS: SYSBOX ISSUE #523"

  docker exec k8s-master sh -c "kubectl create deployment nginx --image=nginx:1.17-alpine"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl expose deployment/nginx --port 80"
  [ "$status" -eq 0 ]

  # modify the tolerations on the deployment such that when a node
  # goes down, the pods get re-scheduled within seconds (this way we
  # don't have to wait for the pod-eviction-timeout which defaults to
  # 5 mins).

  cat > /tmp/depl-patch.yaml <<EOF
spec:
  template:
    spec:
      tolerations:
      - key: "node.kubernetes.io/unreachable"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 2
      - key: "node.kubernetes.io/not-ready"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 2
EOF

  docker cp /tmp/depl-patch.yaml k8s-master:/tmp/depl-patch.yaml
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl patch deployment nginx --patch \"$(cat /tmp/depl-patch.yaml)\""
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_deployment_ready k8s-master default nginx"

  # verify the deployment is up
  local svc_ip=$(k8s_svc_ip k8s-master default nginx)

  retry_run 20 2 "docker exec k8s-master sh -c \"curl -s $svc_ip | grep -q \"Welcome to nginx\"\""
  [ "$status" -eq 0 ]

  # check which worker node the pod is scheduled in
  docker exec k8s-master sh -c "kubectl get pods --selector=app=nginx"
  [ "$status" -eq 0 ]

  local pod=$(echo "${lines[1]}" | awk '{print $1}')
  local node=$(k8s_pod_node k8s-master $pod)

  # delete that node from k8s
  docker exec k8s-master sh -c "kubectl delete node $node"
  [ "$status" -eq 0 ]

  # bring down that node
  docker_stop "$node"
  [ "$status" -eq 0 ]

  # verify deployment is re-scheduled to other worker node(s)
  retry_run 20 2 "[ ! $(k8s_pod_in_node k8s-master $pod $node) ]"
  retry_run 20 2 "k8s_deployment_ready k8s-master default nginx"

  # verify the service is back up
  retry_run 20 2 "docker exec k8s-master sh -c \"curl -s $svc_ip | grep -q \"Welcome to nginx\"\""

  # bring the worker node back up
  # (note: container name = container hostname = kubectl node name)
  local kubeadm_join=$(cat "$test_dir/.kubeadm_join")

  docker_run --rm --name="$node" --hostname="$node" nestybox/ubuntu-bionic-k8s:latest
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd $node

  docker exec "$node" sh -c "$kubeadm_join"
  [ "$status" -eq 0 ]

  retry_run 20 2 "k8s_node_ready k8s-master $node"

  # cleanup

  docker exec k8s-master sh -c "kubectl delete svc nginx"
  [ "$status" -eq 0 ]

  docker exec k8s-master sh -c "kubectl delete deployments.apps nginx"
  [ "$status" -eq 0 ]

  rm /tmp/depl-patch.yaml
}

@test "kind cluster down" {
  local num_workers=$(cat "$test_dir/.k8s_num_workers")
  k8s_cluster_teardown $num_workers
  remove_test_dir
}