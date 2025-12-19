
# 0) Backup the current Makefile just in case
cp -f Makefile Makefile.bak 2>/dev/null || true

# 1) Write a clean Makefile with TAB placeholders
cat > Makefile <<'EOF'
# ===========================================
# Dapr + EKS + SNS/SQS Orchestration Makefile
# ===========================================
# Targets:
#   make check         -> verify required CLIs
#   make cluster       -> create EKS (OIDC + IRSA)
#   make build         -> build & push to ECR
#   make deploy        -> install Dapr & deploy apps
#   make all           -> check + cluster + build + deploy
#   make dry           -> print commands that would run
#   make logs          -> tail OrderService logs
#   make test-publish  -> port-forward & publish sample
#   make clean         -> remove local *.bak
#   make destroy       -> delete cluster (interactive)

# Parameters (override via env or on command line)
ACCOUNT ?= $(AWS_ACCOUNT_ID)
REGION  ?= us-east-1
PREFIX  ?= dapr-eks-pubsub

.PHONY: all check cluster build deploy dry logs test-publish clean destroy

all: check cluster build deploy

check:
@@TAB@@@echo "Validating prerequisites..."
@@TAB@@@if ! command -v aws >/dev/null 2>&1; then echo "Missing: aws"; exit 1; fi
@@TAB@@@if ! command -v kubectl >/dev/null 2>&1; then echo "Missing: kubectl"; exit 1; fi
@@TAB@@@if ! command -v eksctl >/dev/null 2>&1; then echo "Missing: eksctl"; exit 1; fi
@@TAB@@@if ! command -v helm >/dev/null 2>&1; then echo "Missing: helm"; exit 1; fi
@@TAB@@@if ! command -v docker >/dev/null 2>&1; then echo "Missing: docker"; exit 1; fi
@@TAB@@@echo "OK. aws/kubectl/eksctl/helm/docker present."
@@TAB@@@echo "ACCOUNT=$(ACCOUNT)  REGION=$(REGION)  PREFIX=$(PREFIX)"
@@TAB@@@echo "-----------------------------------------------"

cluster:
@@TAB@@@if [ -z "$(ACCOUNT)" ]; then echo "ACCOUNT is required. Use 'make cluster ACCOUNT=<id>' or set AWS_ACCOUNT_ID."; exit 1; fi
@@TAB@@@echo "[cluster] Creating EKS with OIDC + IRSA..."
@@TAB@@@AWS_ACCOUNT_ID=$(ACCOUNT) AWS_REGION=$(REGION) ./eks/create-cluster.sh $(ACCOUNT)
@@TAB@@@echo "[cluster] Done."

build:
@@TAB@@@if [ -z "$(ACCOUNT)" ]; then echo "ACCOUNT is required. Use 'make build ACCOUNT=<id>' or set AWS_ACCOUNT_ID."; exit 1; fi
@@TAB@@@echo "[build] Building & pushing images to ECR..."
@@TAB@@@./scripts/build_push.sh $(ACCOUNT) $(REGION) $(PREFIX)
@@TAB@@@echo "[build] Done."

deploy:
@@TAB@@@echo "[deploy] Installing Dapr and deploying services..."
@@TAB@@@./scripts/deploy.sh
@@TAB@@@echo "[deploy] Done."

dry:
@@TAB@@@if [ -z "$(ACCOUNT)" ]; then echo "ACCOUNT is required. Use 'make dry ACCOUNT=<id>' or set AWS_ACCOUNT_ID."; exit 1; fi
@@TAB@@@echo "DRY-RUN: Would execute the following:"
@@TAB@@@echo "  ./eks/create-cluster.sh $(ACCOUNT)"
@@TAB@@@echo "  ./scripts/build_push.sh $(ACCOUNT) $(REGION) $(PREFIX)"
@@TAB@@@echo "  ./scripts/deploy.sh"

logs:
@@TAB@@@echo "[logs] Tailing OrderService logs (namespace: dapr-apps)"
@@TAB@@@kubectl -n dapr-apps logs deploy/orderservice -f

test-publish:
@@TAB@@@echo "[test] Port-forward ProductService and publish a sample message"
@@TAB@@@set -e; \
    NS=dapr-apps; \
    POD=$$(kubectl -n $$NS get pod -l app=productservice -o jsonpath='{.items[0].metadata.name}'); \
    kubectl -n $$NS port-forward pod/$$POD 18080:8080 >/dev/null 2>&1 & PF=$$!; \
    sleep 2; \
    curl -s -X POST http://localhost:18080/publish \
      -H 'Content-Type: application/json' \
      -d '{"orderId": 7, "item":"demo"}' || true; \
    sleep 2; \
    kill $$PF || true; \
    echo "[test] Published. Use 'make logs' to see subscriber output."

clean:
@@TAB@@@echo "[clean] Removing local *.bak files in k8s/"
@@TAB@@@find k8s -name "*.bak" -delete || true
@@TAB@@@echo "[clean] Done."

destroy:
@@TAB@@@echo "[destroy] Delete EKS cluster via eksctl (interactive)."
@@TAB@@@read -r -p "Enter cluster name (e.g. dapr-introspect-eks): " CL; \
    if [ -n "$$CL" ]; then \
      eksctl delete cluster --name $$CL --wait; \
      echo "Cluster $$CL deleted."; \
    else \
      echo "No cluster name provided. Aborting."; exit 1; \
    fi
EOF

# 2) Replace the placeholder with a literal TAB
# (POSIX-safe; works on macOS)
sed -i '' -e $'s/@@TAB@@/\\\t/g' Makefile

# 3) Remove any Windows CRs (just in case)
perl -pi -e 's/\r$//' Makefile

# 4) Quick sanity checks
grep -n $'\t' Makefile || echo "No lines start with a TAB (grep -n $'\t' Makefile || echo "No lines start with a TAB (unexpected)"
grep -n $'\r$' Makefile || true

# 5) Try it
