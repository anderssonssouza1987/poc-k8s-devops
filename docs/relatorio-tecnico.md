# Relatorio Tecnico — POC Kubernetes Local DevOps

## Decisoes tecnicas

**Kind em vez de minikube.** Kind sobe nodes como containers Docker, o que
permite mapear portas 80/443 do host para o node e validar o Ingress por
NodePort sem tunel. O custo e nao ter provisioner de LoadBalancer, aceito e
documentado.

**Helm com `lint` e `template` antes do `upgrade`.** O pipeline renderiza o
manifesto e valida antes de tocar no cluster. Falha de template vira falha de
build, nao pod em `CrashLoopBackOff`.

**Trivy fixado por digest.** `aquasec/trivy@sha256:8f6bb947...` garante que o
scanner nao muda entre execucoes. Tag flutuante tornaria o resultado nao
reprodutivel.

**`TRIVY_EXIT_CODE=0` no POC.** O scanner roda em modo observacao: encontra a
CVE e nao bloqueia. O build 9 bloqueou o deploy com `exit code 1`; o build 10
encontrou a mesma `CVE-2026-85091` em `zlib1g` e seguiu. A diferenca e uma
variavel de ambiente, nao codigo. Para gate, basta `TRIVY_EXIT_CODE=1`.

**`QG_REQUIRE_CONDITIONS=true`.** Impede quality gate vazio passar como verde.
Sem isso, um projeto sem condicoes configuradas retorna `OK` e o stage aprova
sem avaliar nada.

**Seguranca em runtime.** `runAsUser: 10001`, `readOnlyRootFilesystem: true`,
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`. Exige `emptyDir`
em `/tmp` para o Gunicorn escrever arquivos temporarios.

**Dockerfile multi-stage.** `venv` construido no stage `builder` e copiado para
o stage `runtime`. Reduz superficie de ataque e mantem o `uid 10001`.

## Dificuldades encontradas

**Probe apontando para `/health`.** A aplicacao expoe `/healthz`. O pod ficava
`Running` sem ficar `Ready`, e o `rollout status` estourava timeout.

**`readOnlyRootFilesystem` quebrando o Gunicorn.** Sem `emptyDir` em `/tmp` o
processo falhava ao iniciar. O volume foi adicionado ao chart.

**Porta 8081 ocupada pelo Nexus.** O `port-forward` na 8081 respondia pelo
Nexus, devolvendo `404` em `/healthz` e `200` em `/`. O sintoma imita Ingress
mal configurado. Diagnostico correto: `ss -lntp`.

**HPA em `<unknown>`.** `kubectl top pods` ja respondia antes de qualquer
correcao, provando que a Metrics API estava saudavel. Era latencia de primeira
leitura. Um validador que so checa existencia do HPA daria verde falso.

**Patch de metrics-server duplicado.** `"op":"add"` no fim do array de `args`
nao e idempotente e acumulou `--kubelet-insecure-tls` duas vezes. Corrigido com
`"op":"replace"` no array completo.

## Melhorias futuras

- `TRIVY_EXIT_CODE=1` com allowlist de CVEs aceitas
- Atualizar base Debian para eliminar `CVE-2026-85091` em `zlib1g`
- Assinatura e verificacao de imagens com cosign
- GitOps com ArgoCD no lugar do `helm upgrade` no pipeline
- Blue/Green ou Canary com Argo Rollouts
- Alertas no Grafana para erro 5xx e latencia p95
- Secret via External Secrets Operator em vez de `values.yaml`
- Testes de integracao do chart com `helm unittest`
