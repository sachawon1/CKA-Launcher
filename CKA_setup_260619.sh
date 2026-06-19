#!/bin/bash
# ============================================================
#  CKA 기출문제 실습 환경 구축 스크립트 (킬러코다용)
#  문제 1~16번 전체 초기환경 셋업
#  사용법: chmod +x cka-setup.sh && ./cka-setup.sh [문제번호]
#  예시:   ./cka-setup.sh 1       # 1번 문제만 셋업
#          ./cka-setup.sh all     # 전체 셋업
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
header()  { echo -e "\n${BOLD}${GREEN}========================================${NC}"; \
            echo -e "${BOLD}${GREEN}  $1${NC}"; \
            echo -e "${BOLD}${GREEN}========================================${NC}"; }

wait_for_deployment() {
  local ns=$1
  local name=$2
  info "Deployment $name 준비 대기 중..."
  kubectl rollout status deployment/$name -n $ns --timeout=120s 2>/dev/null || \
    warn "$name 롤아웃 타임아웃 (계속 진행)"
}

wait_for_pod_label() {
  local ns=$1
  local label=$2
  info "Pod ($label) 준비 대기 중..."
  kubectl wait pod -n $ns -l $label --for=condition=Ready --timeout=120s 2>/dev/null || \
    warn "Pod 준비 타임아웃 (계속 진행)"
}

# ============================================================
# 문제 1: Horizontal Pod Autoscaling
# ============================================================
setup_q1() {
  header "문제 1: HPA (Horizontal Pod Autoscaling)"
  info "Namespace: autoscale / Deployment: web-apache 생성"

  kubectl create namespace autoscale --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -n autoscale -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-apache
  namespace: autoscale
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-apache
  template:
    metadata:
      labels:
        app: web-apache
    spec:
      containers:
      - name: web-apache
        image: httpd:2.4
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "100m"
          limits:
            cpu: "200m"
EOF

  # metrics-server 존재 여부 확인 (없으면 설치)
  if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    warn "metrics-server 미발견 → 설치 시도 (HPA 동작에 필요)"
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>/dev/null || \
      warn "metrics-server 설치 실패 (수동 설치 필요할 수 있음)"
  else
    success "metrics-server 이미 존재"
  fi

  wait_for_deployment autoscale web-apache
  success "문제 1 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get deployment -n autoscale"
}

# ============================================================
# 문제 2: Ingress & Service
# ============================================================
setup_q2() {
  header "문제 2: Ingress & Service"
  info "Namespace: web / Deployment: web-app / Service: web-svc 생성"
  info "※ web-ingress는 생성 안 함 - 수험생의 실습 과제!"

  kubectl create namespace web --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -n web -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      containers:
      - name: web-app
        image: nginx:stable
        ports:
        - containerPort: 80
EOF

  kubectl apply -n web -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: web
spec:
  selector:
    app: web-app
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
EOF

  # IngressClass 존재 여부 확인 (nginx)
  if ! kubectl get ingressclass nginx &>/dev/null; then
    warn "IngressClass 'nginx' 미발견 → ingress-nginx 설치 시도"
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml 2>/dev/null || \
      warn "ingress-nginx 설치 실패 (수동 설치 필요)"
  else
    success "IngressClass 'nginx' 이미 존재"
  fi

  # ingress-nginx ValidatingWebhook 제거 (수험생이 Ingress 생성 시 webhook 에러 방지)
  if kubectl get validatingwebhookconfiguration ingress-nginx-admission &>/dev/null; then
    info "ingress-nginx-admission ValidatingWebhook 삭제 (Ingress 생성 차단 방지)"
    kubectl delete validatingwebhookconfiguration ingress-nginx-admission 2>/dev/null || \
      warn "webhook 삭제 실패 (권한 부족일 수 있음)"
  fi

  # /etc/hosts 설정 안내
  if ! grep -q "example.org" /etc/hosts 2>/dev/null; then
    warn "curl 검증을 위해 아래 설정 필요:"
    warn "  echo '127.0.0.1 example.org' | sudo tee -a /etc/hosts"
  fi

  wait_for_deployment web web-app
  success "문제 2 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get deployment,svc -n web"
  echo -e "  ${YELLOW}▶ Ingress 없음 확인:${NC} kubectl get ingress -n web  (빈 결과가 정상)"
  echo -e "  ${YELLOW}※ 실습:${NC} web-ingress (HTTP, path=/web) 생성 후 curl http://example.org/web 검증"
}

# ============================================================
# 문제 3: NodePort
# ============================================================
setup_q3() {
  header "문제 3: NodePort Service"
  info "Namespace: frontend / Deployment: frontend-app 생성 (containerPort 미설정 상태)"

  kubectl create namespace frontend --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -n frontend -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-app
  namespace: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: front-end
  template:
    metadata:
      labels:
        app: front-end
    spec:
      containers:
      - name: frontend
        image: nginx:stable
        # containerPort 는 문제에서 직접 추가 (80)
EOF

  wait_for_deployment frontend frontend-app
  success "문제 3 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get deployment -n frontend"
  echo -e "  ${YELLOW}※ 주의:${NC} containerPort(80) 추가 및 NodePort Service 생성이 실습 과제입니다"
}

# ============================================================
# 문제 4: StorageClass
# ============================================================
setup_q4() {
  header "문제 4: StorageClass"
  info "킬러코다 환경에는 local-path (default) SC가 이미 존재"
  info "→ 별도 SC 생성 불필요!! local-path가 기존 디폴트 SC 역할"

  # local-path가 존재하는지만 확인
  if kubectl get sc local-path &>/dev/null; then
    success "local-path (default) SC 확인 완료 - 실습 환경 준비됨"
  else
    warn "local-path SC 없음 - 환경 확인 필요"
  fi

  success "문제 4 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get sc"
  echo -e "  ${YELLOW}※ 실습:${NC} local-kiddie SC 생성 후 local-path의 default 어노테이션 제거"
}

# ============================================================
# 문제 5: PriorityClass
# ============================================================
setup_q5() {
  header "문제 5: PriorityClass"
  info "Namespace: priority / Deployment: db-app 및 기존 PriorityClass 생성"

  kubectl create namespace priority --dry-run=client -o yaml | kubectl apply -f -

  # 기존 PriorityClass 2개 생성 (문제에서 2번째로 높은 value 사용)
  kubectl apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical-priority
value: 1000000
globalDefault: false
description: "최상위 우선순위"
EOF

  kubectl apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: medium-priority
value: 500000
globalDefault: false
description: "중간 우선순위"
EOF

  kubectl apply -n priority -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db-app
  namespace: priority
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db-app
  template:
    metadata:
      labels:
        app: db-app
    spec:
      containers:
      - name: db
        image: nginx:stable
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
EOF

  wait_for_deployment priority db-app
  success "문제 5 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get pc && kubectl get deployment -n priority"
  echo -e "  ${YELLOW}※ 실습:${NC} 2번째로 높은 value(500000-1=499999)로 high-priority PC 생성 후 db-app에 적용"
}

# ============================================================
# 문제 6: Gateway API Migration
# ============================================================
setup_q6() {
  header "문제 6: Gateway API (Ingress → Gateway 마이그레이션)"
  info "Namespace: web / 마이그레이션 대상 Ingress: gateway-ingress (HTTPS/TLS)"
  info "※ Q2의 web-ingress(HTTP)와 별개로 gateway-ingress(HTTPS)를 초기환경으로 생성"

  kubectl create namespace web --dry-run=client -o yaml | kubectl apply -f -

  # ── Q2 결과물(Deployment/Service)이 없으면 생성 (Q6 단독 실행 대비) ──
  if ! kubectl get deployment web-app -n web &>/dev/null; then
    warn "web-app Deployment 없음 → 자동 생성"
    kubectl apply -n web -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      containers:
      - name: web-app
        image: nginx:stable
        ports:
        - containerPort: 80
EOF
  fi

  if ! kubectl get service web-svc -n web &>/dev/null; then
    warn "web-svc Service 없음 → 자동 생성"
    kubectl apply -n web -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: web
spec:
  selector:
    app: web-app
  ports:
  - port: 80
    targetPort: 80
EOF
  fi

  # ── Step 1: Gateway API CRD 설치 ──
  if ! kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    info "Gateway API CRD 설치 중..."
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml 2>/dev/null || \
      warn "Gateway API CRD 설치 실패 (수동 설치 필요)"
    info "CRD 등록 대기 중 (5초)..."
    sleep 5
  else
    success "Gateway API CRD 이미 존재"
  fi

  # ── Step 2: nginx-gateway-fabric 컨트롤러 설치 ──
  if ! kubectl get deployment -n nginx-gateway nginx-gateway &>/dev/null; then
    info "nginx-gateway-fabric 설치 중..."
    kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v1.4.0/deploy/crds.yaml 2>/dev/null || \
      warn "nginx-gateway-fabric CRD 설치 실패 (네트워크 제한)"
    kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v1.4.0/deploy/default/deploy.yaml 2>/dev/null || \
      warn "nginx-gateway-fabric 설치 실패 (네트워크 제한)"
    info "nginx-gateway-fabric 준비 대기 중 (15초)..."
    sleep 15
    kubectl wait pod -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway \
      --for=condition=Ready --timeout=60s 2>/dev/null || \
      warn "nginx-gateway-fabric Pod 준비 타임아웃 (계속 진행)"
  else
    success "nginx-gateway-fabric 이미 존재"
  fi

  # ── Step 3: GatewayClass(nginx) 생성 ──
  kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: gateway.nginx.org/nginx-gateway-controller
  description: "nginx GatewayClass for CKA practice"
EOF
  success "GatewayClass 'nginx' 생성 완료"

  # ── Step 4: TLS Secret(web-tls) 생성 ──
  if command -v openssl &>/dev/null; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /tmp/web-tls.key \
      -out /tmp/web-tls.crt \
      -subj "/CN=gateway.web.k8s.local/O=test" \
      -addext "subjectAltName=DNS:gateway.web.k8s.local" 2>/dev/null
    kubectl create secret tls web-tls \
      --key=/tmp/web-tls.key \
      --cert=/tmp/web-tls.crt \
      -n web --dry-run=client -o yaml | kubectl apply -f -
    success "TLS Secret 'web-tls' 생성 완료"
  else
    warn "openssl 미설치 → 더미 TLS Secret 생성"
    kubectl apply -n web -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: web-tls
  namespace: web
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJJVEFOCG==
  tls.key: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQo=
EOF
  fi

  # ── Step 5: ingress-nginx ValidatingWebhook 제거 후 HTTPS Ingress 생성 ──
  # webhook 살아있으면 Ingress 생성 시 "failed calling webhook" 에러 발생!
  # (webhook Pod가 아직 Ready 아닐 때 / 네트워크 정책으로 막힐 때 모두 해당)
  if kubectl get validatingwebhookconfiguration ingress-nginx-admission &>/dev/null; then
    info "ingress-nginx-admission ValidatingWebhook 삭제 (Ingress 생성 차단 방지)"
    kubectl delete validatingwebhookconfiguration ingress-nginx-admission 2>/dev/null || \
      warn "webhook 삭제 실패 (권한 부족일 수 있음 - 계속 진행)"
  fi

  # Q2의 web-ingress(HTTP)와 완전히 별개 리소스!
  # 수험생은 이 gateway-ingress를 Gateway+HTTPRoute로 마이그레이션 후 삭제
  kubectl apply -n web -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gateway-ingress
  namespace: web
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - gateway.web.k8s.local
    secretName: web-tls
  rules:
  - host: gateway.web.k8s.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port:
              number: 80
EOF
  success "HTTPS gateway-ingress 생성 완료 (마이그레이션 대상)"

  # ── Step 6: /etc/hosts 에 gateway.web.k8s.local 등록 ──
  # curl 검증 시 DNS 해석 실패(curl: (6) Could not resolve host) 방지
  GATEWAY_HOST="gateway.web.k8s.local"
  if ! grep -q "$GATEWAY_HOST" /etc/hosts 2>/dev/null; then
    # NodeIP 우선, 없으면 127.0.0.1
    NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "127.0.0.1")
    echo "${NODE_IP} ${GATEWAY_HOST}" | sudo tee -a /etc/hosts > /dev/null
    success "/etc/hosts 에 '${NODE_IP} ${GATEWAY_HOST}' 추가 완료"
  else
    success "/etc/hosts 에 $GATEWAY_HOST 이미 등록됨"
  fi

  success "문제 6 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get ingress -n web"
  echo -e "       → gateway-ingress (HTTPS, 마이그레이션 대상) 존재 확인"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get ingress gateway-ingress -n web -o yaml  ← tls 섹션 있어야 함!"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get gatewayclass                             ← nginx 있어야 함!"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get secret web-tls -n web"
  echo -e "  ${YELLOW}▶ 확인:${NC} grep gateway.web.k8s.local /etc/hosts               ← hosts 등록 확인!"
  echo -e "  ${YELLOW}※ 실습:${NC} Gateway(web-gateway) + HTTPRoute(web-route) 생성 후 gateway-ingress 삭제"
  echo -e "  ${YELLOW}※ curl:${NC} curl -k https://gateway.web.k8s.local  (-k 는 자체서명 인증서 무시)"
}

# ============================================================
# 문제 7: Resource Allocation
# ============================================================
setup_q7() {
  header "문제 7: Resource Allocation (Pending Pod 수정)"
  info "Namespace: namu / Deployment: synergy-average (과도한 Request로 Pending 유발)"

  kubectl create namespace namu --dry-run=client -o yaml | kubectl apply -f -

  # 노드의 실제 allocatable 확인 후 일부러 과도한 request 설정
  NODE_CPU=$(kubectl get node -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || echo "2")
  NODE_MEM=$(kubectl get node -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null || echo "4Gi")
  info "노드 Allocatable - CPU: $NODE_CPU / Memory: $NODE_MEM"

  kubectl apply -n namu -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: synergy-average
  namespace: namu
spec:
  replicas: 3
  selector:
    matchLabels:
      app: synergy-average
  template:
    metadata:
      labels:
        app: synergy-average
    spec:
      containers:
      - name: app
        image: nginx:stable
        resources:
          requests:
            cpu: "900m"       # 3개 replicas × 900m = 2700m → 대부분 환경에서 Pending 유발
            memory: "9Gi"     # 3개 replicas × 9Gi = 27Gi → 대부분 환경에서 Pending 유발
          limits:
            cpu: "1100m"
            memory: "10Gi"
EOF

  success "문제 7 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get pod -n namu (일부 Pending 상태 예상)"
  echo -e "  ${YELLOW}※ 실습:${NC} replicas=0으로 scale 후 Request 수정 → replicas=3 복구"
}

# ============================================================
# 문제 8: PV 재이용
# ============================================================
setup_q8() {
  header "문제 8: PV 재이용 (삭제된 PVC/Deployment 복원)"
  info "PV 생성 → PVC/Deployment 생성 → PVC/Deployment 삭제 (PV는 Released 상태로 남김)"

  kubectl create namespace mariadb --dry-run=client -o yaml | kubectl apply -f -

  # hostPath 기반 PV 생성 (로컬 환경)
  kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mariadb-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/mariadb-data
EOF

  # PVC 생성 후 바인드 확인
  kubectl apply -n mariadb -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-temp-pvc
  namespace: mariadb
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ""
  volumeName: mariadb-pv
EOF

  # Deployment 생성
  kubectl apply -n mariadb -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
  namespace: mariadb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
      - name: mariadb
        image: mariadb:10.6
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: "rootpass"
        volumeMounts:
        - name: mariadb-storage
          mountPath: /var/lib/mysql
      volumes:
      - name: mariadb-storage
        persistentVolumeClaim:
          claimName: mariadb-temp-pvc
EOF

  sleep 3

  # mariadb-deployment.yaml 파일 생성 (수험생이 수정할 파일)
  cat > ~/mariadb-deployment.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
  namespace: mariadb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
      - name: mariadb
        image: mariadb:10.6
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: "rootpass"
        # TODO: volumeMounts 추가 필요
      # TODO: volumes 추가 필요
YAML

  info "Deployment와 PVC 삭제 (PV를 Released 상태로 만들기)..."
  kubectl delete deployment mariadb -n mariadb 2>/dev/null || true
  kubectl delete pvc mariadb-temp-pvc -n mariadb 2>/dev/null || true

  # PV의 claimRef 제거 (Available 상태로 복구 - 재이용 가능하게)
  sleep 2
  kubectl patch pv mariadb-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || \
    kubectl patch pv mariadb-pv --type=merge -p='{"spec":{"claimRef":null}}' 2>/dev/null || \
    warn "PV claimRef 제거 실패 - 수동으로 kubectl edit pv mariadb-pv 실행 필요"

  success "문제 8 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get pv (Available 상태 확인)"
  echo -e "  ${YELLOW}파일:${NC}  ~/mariadb-deployment.yaml (수정 후 apply)"
}

# ============================================================
# 문제 9: cri-dockerd 설정
# ============================================================
setup_q9() {
  header "문제 9: cri-dockerd 설정"
  info ".deb 파일 다운로드 및 sysctl 초기 상태 구성"

  # Docker API 버전 확인 → 호환 cri-dockerd 버전 결정
  # Docker API 1.44 이상이면 cri-dockerd 0.3.15는 호환 불가 → 0.3.16 이상 필요
  DOCKER_API_VER=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo "0.0")
  info "Docker API version: ${DOCKER_API_VER}"

  DOCKER_API_MAJOR=$(echo ${DOCKER_API_VER} | cut -d. -f1)
  DOCKER_API_MINOR=$(echo ${DOCKER_API_VER} | cut -d. -f2)
  if [ "${DOCKER_API_MAJOR}" -gt 1 ] || { [ "${DOCKER_API_MAJOR}" -eq 1 ] && [ "${DOCKER_API_MINOR}" -ge 44 ]; }; then
    CRI_VERSION="0.3.16"
    CRI_DEB="cri-dockerd_0.3.16.3-0.ubuntu-jammy_amd64.deb"
    CRI_URL="https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.16/cri-dockerd_0.3.16.3-0.ubuntu-jammy_amd64.deb"
    warn "Docker API >= 1.44 검출 → cri-dockerd ${CRI_VERSION} 사용 (0.3.15는 API 비호환)"
  else
    CRI_VERSION="0.3.15"
    CRI_DEB="cri-dockerd_0.3.15.3-0.ubuntu-jammy_amd64.deb"
    CRI_URL="https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.15/cri-dockerd_0.3.15.3-0.ubuntu-jammy_amd64.deb"
    info "Docker API < 1.44 → cri-dockerd ${CRI_VERSION} 사용"
  fi

  # 기존 버전 .deb 파일 제거 후 재다운로드
  rm -f ~/cri-dockerd_0.3.15*.deb ~/cri-dockerd_0.3.16*.deb 2>/dev/null || true

  # cri-dockerd .deb 파일 다운로드
  if [ ! -f ~/${CRI_DEB} ]; then
    info "cri-dockerd ${CRI_VERSION} .deb 파일 다운로드 중..."
    cd ~
    curl -sLo ~/${CRI_DEB} "${CRI_URL}" 2>/dev/null || \
      warn ".deb 파일 다운로드 실패 (네트워크 제한 환경)"
  else
    success ".deb 파일 이미 존재: ${CRI_DEB}"
  fi

  # sysctl 설정 파일이 없는 상태 확인
  if [ -f /etc/sysctl.d/k8s.conf ]; then
    warn "/etc/sysctl.d/k8s.conf 이미 존재 → 백업 후 삭제"
    sudo cp /etc/sysctl.d/k8s.conf /etc/sysctl.d/k8s.conf.bak
    sudo rm /etc/sysctl.d/k8s.conf
  fi

  success "문제 9 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} ls ~/ | grep cri-dockerd"
  echo -e "  ${YELLOW}※ 실습:${NC} dpkg -i ~/${CRI_DEB} → systemctl enable --now cri-docker → sysctl 설정"
}

# ============================================================
# 문제 10: CNI 플러그인 (Flannel / Calico)
# ============================================================
setup_q10() {
  header "문제 10: CNI 플러그인 설치"
  info "CNI 미설치 상태 시뮬레이션 (기존 CNI Pod 확인)"

  warn "이 문제는 kubeadm으로 CNI 없이 초기화된 클러스터가 필요합니다."
  warn "현재 CNI 상태 확인:"
  kubectl get po -A 2>/dev/null | grep -E "flannel|calico|weave|cilium" || \
    info "CNI 관련 Pod 없음 (정상 - 설치 필요 상태)"

  # kube-controller-manager에서 CIDR 확인
  if [ -f /etc/kubernetes/manifests/kube-controller-manager.yaml ]; then
    CLUSTER_CIDR=$(grep -i cluster-cidr /etc/kubernetes/manifests/kube-controller-manager.yaml | awk -F= '{print $2}' | tr -d ' ')
    info "클러스터 CIDR: ${CLUSTER_CIDR:-'확인 불가'}"
  fi

  success "문제 10 환경 확인 완료"
  echo -e "  ${YELLOW}▶ 실습 분기:${NC}"
  echo -e "     Network Policy 요구 있음 → Calico 설치"
  echo -e "     Network Policy 요구 없음 → Flannel 설치"
  echo -e "  ${YELLOW}▶ CIDR 확인:${NC} cat /etc/kubernetes/manifests/kube-controller-manager.yaml | grep cidr"
}

# ============================================================
# 문제 11: Sidecar 추가
# ============================================================
setup_q11() {
  header "문제 11: Sidecar Container 추가"
  info "Namespace: loggingns / Deployment: logging-app 생성 (sidecar 없는 상태)"

  kubectl create namespace loggingns --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -n loggingns -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logging-app
  namespace: loggingns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: logging-app
  template:
    metadata:
      labels:
        app: logging-app
    spec:
      containers:
      - name: main-app
        image: busybox:stable
        command: ['/bin/sh', '-c']
        args:
        - |
          mkdir -p /var/log
          while true; do
            echo "$(date): application log entry" >> /var/log/app.log
            sleep 5
          done
        # volumeMounts는 수험생이 추가 (실습 과제)
EOF

  wait_for_deployment loggingns logging-app
  success "문제 11 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get deployment -n loggingns"
  echo -e "  ${YELLOW}※ 실습:${NC} sidecar 컨테이너 추가 + emptyDir 볼륨 공유 설정"
}

# ============================================================
# 문제 12: Helm (ArgoCD)
# ============================================================
setup_q12() {
  header "문제 12: Helm으로 ArgoCD 설치"
  info "Helm 설치 여부 확인 및 argo repo 미등록 상태 확인"

  # Helm 설치 확인
  if ! command -v helm &>/dev/null; then
    warn "Helm 미설치 → 설치 시도"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash 2>/dev/null || \
      warn "Helm 자동 설치 실패 (수동 설치 필요)"
  else
    success "Helm 설치됨: $(helm version --short 2>/dev/null)"
  fi

  # argo repo가 등록되어 있으면 제거 (초기 상태)
  if helm repo list 2>/dev/null | grep -q "argo"; then
    warn "기존 argo repo 제거 (초기 상태 구성)"
    helm repo remove argo 2>/dev/null || true
  fi

  # argocd namespace 제거 (초기 상태)
  kubectl delete namespace argocd --ignore-not-found=true 2>/dev/null || true

  success "문제 12 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} helm repo list (argo 없어야 함)"
  echo -e "  ${YELLOW}※ 실습:${NC} helm repo add → helm template (CRD 제외) → helm install"
}

# ============================================================
# 문제 13: Network Policy
# ============================================================
setup_q13() {
  header "문제 13: Network Policy"
  info "Namespace: frontend, backend / Deployment 생성 / deny-all NetworkPolicy 적용"

  kubectl create namespace frontend --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace backend  --dry-run=client -o yaml | kubectl apply -f -

  # frontend Deployment
  kubectl apply -n frontend -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: frontend
        image: curlimages/curl:latest
        command: ['/bin/sh', '-c', 'while true; do sleep 60; done']
EOF

  # backend Deployment
  kubectl apply -n backend -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: backend
        image: nginx:stable
        ports:
        - containerPort: 80
EOF

  # backend Service
  kubectl apply -n backend -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: backend
spec:
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 80
EOF

  # deny-all NetworkPolicy (backend)
  kubectl apply -n backend -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: backend
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

  # netpol 디렉토리 및 샘플 YAML 생성
  mkdir -p ~/netpol

  cat > ~/netpol/allow-frontend-to-backend.yaml <<'YAML'
# 조건에 맞는 NetworkPolicy (이것을 선택하여 apply)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-frontend
  namespace: backend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: frontend
      podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 80
YAML

  cat > ~/netpol/allow-all.yaml <<'YAML'
# 너무 관대한 정책 (least permissive 조건 불충족 - 선택하지 말 것)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-ingress
  namespace: backend
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - {}
YAML

  cat > ~/netpol/allow-namespace-only.yaml <<'YAML'
# namespace만 허용 (pod 레벨 필터 없음 - least permissive 아님)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-frontend-ns
  namespace: backend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: frontend
    ports:
    - protocol: TCP
      port: 80
YAML

  # frontend namespace 라벨 설정
  kubectl label namespace frontend kubernetes.io/metadata.name=frontend --overwrite 2>/dev/null || true

  wait_for_deployment frontend frontend
  wait_for_deployment backend backend
  success "문제 13 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get netpol -n backend && ls ~/netpol/"
  echo -e "  ${YELLOW}※ 실습:${NC} netpol/ 디렉토리의 3개 YAML 중 가장 restrictive한 것 선택"
}

# ============================================================
# 문제 14: Cluster Troubleshooting
# ============================================================
setup_q14() {
  header "문제 14: Cluster Troubleshooting (API Server 장애)"
  info "kube-apiserver.yaml의 etcd-servers IP를 잘못된 값으로 변경"

  APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"

  if [ ! -f "$APISERVER_MANIFEST" ]; then
    warn "$APISERVER_MANIFEST 파일 없음 (kubeadm 클러스터 아님)"
    warn "이 문제는 kubeadm으로 구축된 control plane 노드에서 실습해야 합니다"
    return
  fi

  # 백업 생성
  sudo cp "$APISERVER_MANIFEST" "${APISERVER_MANIFEST}.bak"
  info "백업 생성: ${APISERVER_MANIFEST}.bak"

  # etcd-servers IP를 잘못된 값으로 변경
  sudo sed -i 's|--etcd-servers=https://127.0.0.1:2379|--etcd-servers=https://128.0.0.1:2379|g' "$APISERVER_MANIFEST"

  info "etcd-servers를 127.0.0.1 → 128.0.0.1 로 변경 (장애 유발)"
  warn "API Server가 잠시 후 재시작됩니다. kubectl 명령이 실패하는 것이 정상입니다."
  warn "복구 방법: sudo sed -i 's|128.0.0.1:2379|127.0.0.1:2379|' $APISERVER_MANIFEST"

  success "문제 14 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get no (연결 거부 에러 발생 예상)"
  echo -e "  ${YELLOW}※ 실습:${NC} crictl logs로 원인 파악 → kube-apiserver.yaml 수정 → kubelet restart"
}

# ============================================================
# 문제 15: CRD 추출
# ============================================================
setup_q15() {
  header "문제 15: CRD 추출 (cert-manager)"
  info "cert-manager CRD 설치"

  # cert-manager 설치 여부 확인
  if ! kubectl get crd certificates.cert-manager.io &>/dev/null; then
    info "cert-manager CRD 설치 중..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.crds.yaml 2>/dev/null || \
      warn "cert-manager CRD 설치 실패 (네트워크 제한)"
  else
    success "cert-manager CRD 이미 존재"
  fi

  success "문제 15 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get crd | grep cert-manager"
  echo -e "  ${YELLOW}※ 실습:${NC}"
  echo -e "     kubectl get crd | grep cert-manager > cert-manager-crd.yaml"
  echo -e "     kubectl explain certificate.spec.subject > subject.yaml"
}

# ============================================================
# 문제 16: ConfigMap 수정 (TLS 1.2)
# ============================================================
setup_q16() {
  header "문제 16: ConfigMap 수정 (TLS 설정)"
  info "Namespace: nginx-ns / ConfigMap: app-config (TLSv1.3만 허용) / Deployment: config-app"

  kubectl create namespace nginx-ns --dry-run=client -o yaml | kubectl apply -f -

  # TLS 인증서 생성
  if command -v openssl &>/dev/null; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /tmp/nginx-tls.key \
      -out /tmp/nginx-tls.crt \
      -subj "/CN=web.k8s.local/O=test" \
      -addext "subjectAltName=DNS:web.k8s.local" 2>/dev/null
    kubectl create secret tls nginx-tls \
      --key=/tmp/nginx-tls.key \
      --cert=/tmp/nginx-tls.crt \
      -n nginx-ns --dry-run=client -o yaml | kubectl apply -f -
  fi

  # ConfigMap 생성 (TLSv1.3만 허용 - 문제 상태)
  kubectl apply -n nginx-ns -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: nginx-ns
data:
  nginx.conf: |
    server {
      listen 443 ssl;
      server_name web.k8s.local;

      ssl_certificate     /etc/nginx/ssl/tls.crt;
      ssl_certificate_key /etc/nginx/ssl/tls.key;
      ssl_protocols TLSv1.3;

      location / {
        return 200 'Hello from nginx!\n';
        add_header Content-Type text/plain;
      }
    }
EOF

  # Deployment 생성 (ConfigMap 마운트)
  kubectl apply -n nginx-ns -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-app
  namespace: nginx-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: config-app
  template:
    metadata:
      labels:
        app: config-app
    spec:
      containers:
      - name: nginx
        image: nginx:stable
        ports:
        - containerPort: 443
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: nginx.conf
        - name: tls-secret
          mountPath: /etc/nginx/ssl
          readOnly: true
      volumes:
      - name: nginx-config
        configMap:
          name: app-config
      - name: tls-secret
        secret:
          secretName: nginx-tls
EOF

  # web.k8s.local 검증용 안정 엔드포인트: ClusterIP Service
  # (Pod IP는 rollout restart 시 바뀌어 /etc/hosts가 낡으므로, restart에도 불변인
  #  Service의 ClusterIP를 사용한다. 실제 시험도 Service/Ingress 경유 구성에 가깝다.)
  wait_for_deployment nginx-ns config-app
  kubectl apply -n nginx-ns -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: config-app
  namespace: nginx-ns
spec:
  selector:
    app: config-app
  ports:
  - port: 443
    targetPort: 443
    protocol: TCP
EOF
  CLUSTER_IP=$(kubectl get svc config-app -n nginx-ns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
  if [ -n "$CLUSTER_IP" ]; then
    sudo sed -i '/web\.k8s\.local/d' /etc/hosts
    echo "${CLUSTER_IP} web.k8s.local" | sudo tee -a /etc/hosts > /dev/null
    success "/etc/hosts에 '${CLUSTER_IP} web.k8s.local' 등록 완료 (Service ClusterIP / restart에도 안정)"
  else
    warn "ClusterIP 획득 실패 → 수동 등록 필요:"
    warn "  CLUSTER_IP=\$(kubectl get svc config-app -n nginx-ns -o jsonpath='{.spec.clusterIP}')"
    warn "  echo '\${CLUSTER_IP} web.k8s.local' | sudo tee -a /etc/hosts"
  fi

  success "문제 16 환경 구축 완료"
  echo -e "  ${YELLOW}▶ 확인:${NC} kubectl get cm app-config -n nginx-ns -o yaml"
  echo -e "  ${YELLOW}※ 실습:${NC} ssl_protocols에 TLSv1.2 추가 → rollout restart → immutable: true 설정"
  echo -e "  ${YELLOW}※ curl:${NC} curl -k --tls-max 1.2 https://web.k8s.local  (수정 후 'Hello from nginx!' 면 성공 / -k=자체서명)"
}

# ============================================================
# 전체 요약 출력
# ============================================================
print_summary() {
  echo ""
  echo -e "${BOLD}${CYAN}============================================================${NC}"
  echo -e "${BOLD}${CYAN}   CKA 실습 환경 구축 완료 요약${NC}"
  echo -e "${BOLD}${CYAN}============================================================${NC}"
  echo ""
  printf "%-6s %-25s %-30s\n" "번호" "주제" "확인 명령어"
  printf "%-6s %-25s %-30s\n" "------" "-------------------------" "------------------------------"
  printf "%-6s %-25s %-30s\n" "Q1"  "HPA"                    "kubectl get deploy -n autoscale"
  printf "%-6s %-25s %-30s\n" "Q2"  "Ingress & Service"      "kubectl get svc,ing -n web"
  printf "%-6s %-25s %-30s\n" "Q3"  "NodePort"               "kubectl get deploy -n frontend"
  printf "%-6s %-25s %-30s\n" "Q4"  "StorageClass"           "kubectl get sc"
  printf "%-6s %-25s %-30s\n" "Q5"  "PriorityClass"          "kubectl get pc"
  printf "%-6s %-25s %-30s\n" "Q6"  "Gateway API"            "kubectl get ingress -n web"
  printf "%-6s %-25s %-30s\n" "Q7"  "Resource Allocation"    "kubectl get po -n namu"
  printf "%-6s %-25s %-30s\n" "Q8"  "PV 재이용"              "kubectl get pv"
  printf "%-6s %-25s %-30s\n" "Q9"  "cri-dockerd"            "ls ~/ | grep cri-dockerd"
  printf "%-6s %-25s %-30s\n" "Q10" "CNI 플러그인"           "kubectl get po -A"
  printf "%-6s %-25s %-30s\n" "Q11" "Sidecar"                "kubectl get deploy -n loggingns"
  printf "%-6s %-25s %-30s\n" "Q12" "Helm (ArgoCD)"          "helm repo list"
  printf "%-6s %-25s %-30s\n" "Q13" "Network Policy"         "ls ~/netpol/"
  printf "%-6s %-25s %-30s\n" "Q14" "Cluster Troubleshoot"   "kubectl get no"
  printf "%-6s %-25s %-30s\n" "Q15" "CRD 추출"               "kubectl get crd | grep cert"
  printf "%-6s %-25s %-30s\n" "Q16" "ConfigMap (TLS)"        "kubectl get cm -n nginx-ns"
  echo ""
}

# ============================================================
# 메인 실행
# ============================================================
main() {
  local target="${1:-all}"

  echo -e "${BOLD}${GREEN}"
  echo "  ██████╗██╗  ██╗ █████╗     ███████╗███████╗████████╗██╗   ██╗██████╗ "
  echo " ██╔════╝██║ ██╔╝██╔══██╗    ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗"
  echo " ██║     █████╔╝ ███████║    ███████╗█████╗     ██║   ██║   ██║██████╔╝"
  echo " ██║     ██╔═██╗ ██╔══██║    ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ "
  echo " ╚██████╗██║  ██╗██║  ██║    ███████║███████╗   ██║   ╚██████╔╝██║     "
  echo "  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝    ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝     "
  echo -e "${NC}"
  echo -e "  ${CYAN}CKA 기출문제 실습 환경 구축 스크립트 for KillerCoda${NC}"
  echo ""

  case "$target" in
    1|q1)   setup_q1  ;;
    2|q2)   setup_q2  ;;
    3|q3)   setup_q3  ;;
    4|q4)   setup_q4  ;;
    5|q5)   setup_q5  ;;
    6|q6)   setup_q6  ;;
    7|q7)   setup_q7  ;;
    8|q8)   setup_q8  ;;
    9|q9)   setup_q9  ;;
    10|q10) setup_q10 ;;
    11|q11) setup_q11 ;;
    12|q12) setup_q12 ;;
    13|q13) setup_q13 ;;
    14|q14) setup_q14 ;;
    15|q15) setup_q15 ;;
    16|q16) setup_q16 ;;
    all)
      setup_q1  && setup_q2  && setup_q3  && setup_q4  &&
      setup_q5  && setup_q6  && setup_q7  && setup_q8  &&
      setup_q9  && setup_q10 && setup_q11 && setup_q12 &&
      setup_q13 && setup_q15 && setup_q16
      # Q14는 클러스터 파괴적이므로 all에서 제외
      warn "Q14(클러스터 장애 유발)는 안전상 all에서 제외됨"
      warn "단독 실행: ./cka-setup.sh 14"
      print_summary
      ;;
    *)
      echo "사용법: $0 [1-16 | all]"
      echo "예시:   $0 1     # 1번 문제만"
      echo "        $0 all   # 전체 (Q14 제외)"
      exit 1
      ;;
  esac
}

main "$@"