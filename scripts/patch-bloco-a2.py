#!/usr/bin/env python3
"""Bloco A.2: parte do Jenkinsfile que falhou no A.1 + limpeza dos .bak.

Trabalha por linha, sem depender de indentacao ou espacamento exato.
Idempotente: rodar duas vezes nao duplica nada.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JB = ROOT / "Jenkinsfile"


def indentacao(linha):
    return linha[: len(linha) - len(linha.lstrip())]


linhas = JB.read_text(encoding="utf-8").splitlines()
alterado = False


def gravar_jenkinsfile():
    JB.write_text("\n".join(linhas) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# 1. PROM_STACK_RELEASE no bloco environment
# --------------------------------------------------------------------------
if "PROM_STACK_RELEASE" in "\n".join(linhas):
    print("  = Jenkinsfile: PROM_STACK_RELEASE ja presente")
else:
    alvo = next((i for i, l in enumerate(linhas) if l.strip().startswith("KUBECONFIG")), None)
    if alvo is None:
        alvo = next((i for i, l in enumerate(linhas) if "QG_REQUIRE_CONDITIONS" in l), None)
    if alvo is None:
        sys.exit("ERRO: nao achei ancora no bloco environment do Jenkinsfile")
    linhas.insert(alvo + 1, f"{indentacao(linhas[alvo])}PROM_STACK_RELEASE = 'kube-prom'")
    alterado = True
    print(f"  + Jenkinsfile: PROM_STACK_RELEASE inserido apos a linha {alvo + 1}")

# --------------------------------------------------------------------------
# 2. Bloco SM_FLAG antes do helm lint
# --------------------------------------------------------------------------
if "SM_FLAG=" in "\n".join(linhas):
    print("  = Jenkinsfile: bloco SM_FLAG ja presente")
else:
    idx = next((i for i, l in enumerate(linhas) if 'helm lint "${CHART_DIR}"' in l), None)
    if idx is None:
        sys.exit("ERRO: nao achei a linha do helm lint no Jenkinsfile")
    ind = indentacao(linhas[idx])
    bloco = [
        "if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then",
        '  SM_FLAG="--set serviceMonitor.enabled=true --set serviceMonitor.labels.release=${PROM_STACK_RELEASE}"',
        "else",
        '  echo "AVISO: CRD ServiceMonitor ausente; observabilidade da app desabilitada"',
        '  SM_FLAG="--set serviceMonitor.enabled=false"',
        "fi",
    ]
    for k, b in enumerate(bloco):
        linhas.insert(idx + k, ind + b)
    alterado = True
    print(f"  + Jenkinsfile: bloco SM_FLAG inserido antes da linha {idx + 1}")

# --------------------------------------------------------------------------
# 3. ${SM_FLAG} nos dois comandos helm (template e upgrade)
# --------------------------------------------------------------------------
if "${SM_FLAG} \\" in "\n".join(linhas):
    print("  = Jenkinsfile: ${SM_FLAG} ja presente nos comandos helm")
else:
    novas = []
    n = 0
    for l in linhas:
        novas.append(l)
        if "imagePullSecrets[0].name=nexus-regcred" in l and l.rstrip().endswith("\\"):
            novas.append(indentacao(l) + "${SM_FLAG} \\")
            n += 1
    if n != 2:
        sys.exit(f"ERRO: esperava 2 linhas de imagePullSecrets, encontrou {n}")
    linhas = novas
    alterado = True
    print(f"  + Jenkinsfile: ${{SM_FLAG}} adicionado em {n} comandos helm")

if alterado:
    gravar_jenkinsfile()

# --------------------------------------------------------------------------
# 4. Limpeza dos .bak (nao rodou no A.1)
# --------------------------------------------------------------------------
if (ROOT / ".git").exists():
    rastreados = subprocess.run(["git", "ls-files", "*.bak*"], cwd=ROOT,
                                capture_output=True, text=True).stdout.split()
    if rastreados:
        for arq in rastreados:
            subprocess.run(["git", "rm", "--cached", "--quiet", arq], cwd=ROOT, check=False)
            print(f"  - {arq}: removido do indice")
    else:
        print("  = nenhum .bak versionado")
    gitignore = ROOT / ".gitignore"
    atual = gitignore.read_text(encoding="utf-8") if gitignore.exists() else ""
    if "*.bak.*" not in atual:
        gitignore.write_text(atual.rstrip("\n") + "\n*.bak.*\n", encoding="utf-8")
        print("  + .gitignore: *.bak.*")

print("\nConcluido.")
