# POC Kubernetes Local DevOps

Aplicacao Python (Flask + Gunicorn) entregue por pipeline Jenkins, publicada em
registry Nexus, escaneada por Trivy, validada por SonarQube e implantada em
cluster Kind via Helm.

## Pre-requisitos

- WSL2 Ubuntu 24.04
- Docker 29.x
- Kind v0.34.0
- kubectl v1.37
- Helm 3.x
- 8 GB de RAM livres (o stack de observabilidade consome ~2 GB)

## Subida do ambiente

```bash
kind create cluster --config cluster/kind-config.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--cert-dir=/tmp","--secure-port=10250","--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname","--kubelet-use-node-status-port","--metric-resolution=15s","--kubelet-insecure-tls"]}]'
docker compose up -d
bash scripts/nexus-setup.sh
```

## Pipeline

Job `poc-k8s-app` no Jenkins (`http://localhost:8080`). Stages: Checkout,
Testes (pytest + cobertura), SonarQube, Quality Gate, Build, Trivy, Deploy.

Variaveis relevantes no `Jenkinsfile`:

- `TRIVY_IMAGE` — scanner fixado por digest SHA256
- `TRIVY_EXIT_CODE` — `0` em modo observacao, `1` para bloquear
- `QG_REQUIRE_CONDITIONS` — `true` impede quality gate vazio

## Acesso a aplicacao

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -H 'Host: poc-k8s.local' "http://$NODE_IP:30619/healthz"
curl -H 'Host: poc-k8s.local' "http://$NODE_IP:30619/"
```

Alternativa sem NodePort:

```bash
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 18081:80 &
curl -H 'Host: poc-k8s.local' http://127.0.0.1:18081/healthz
```

## Rollback

```bash
helm history poc-k8s-app -n poc-k8s
helm rollback poc-k8s-app 1 -n poc-k8s
kubectl -n poc-k8s rollout status deploy/poc-k8s-app --timeout=120s
```

Rollback de imagem sem Helm:

```bash
kubectl -n poc-k8s set image deploy/poc-k8s-app \
  poc-k8s-app=nexus:5001/poc-k8s-app:<tag-anterior>
```

## Troubleshooting

**Porta 8081 ocupada.** O Nexus usa 8081 por padrao. Um `port-forward` nessa
porta responde pelo Nexus, nao pelo Ingress, e devolve `404` em `/healthz` com
`200` em `/`. Use porta livre: `ss -lntp | grep 8081`.

**HPA com `TARGETS <unknown>`.** Latencia de primeira leitura de metrica, nao
defeito. Aguarde 60 a 90 s apos criar o HPA e confirme com `kubectl top pods -n poc-k8s`.

**Ingress com `ADDRESS` vazio.** Normal em Kind: nao existe provisioner de
LoadBalancer. Use o NodePort do controller ou port-forward.

**Probe falhando com `404`.** A aplicacao expoe `/healthz`, nao `/health`.
Confira com `kubectl -n poc-k8s get deploy poc-k8s-app -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}'`.

**Gunicorn nao sobe com `readOnlyRootFilesystem`.** Precisa de `emptyDir` em
`/tmp`. O chart ja monta o volume `tmp`.

## Validacao

```bash
./scripts/validate-poc.sh; echo "exit=$?"
```

22 checagens: replicas, security context, runtime, probes, HPA, Ingress, HTTP
externo e relatorio Trivy. `exit=0` significa todos os requisitos aprovados.

## Seguranca

Pod e container rodam com `runAsUser: 10001`, `readOnlyRootFilesystem: true`,
`allowPrivilegeEscalation: false` e `capabilities.drop: [ALL]`. Politica Kyverno
`disallow-latest-tag` em modo `Enforce` bloqueia imagens com tag `:latest`.
