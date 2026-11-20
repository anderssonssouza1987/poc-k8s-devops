#!/usr/bin/env python3
"""Bloco C: gera README, guia de troubleshooting e relatorio tecnico da entrega."""
import pathlib
import sys

DOCS = pathlib.Path("docs")
DOCS.mkdir(exist_ok=True)

README = r"""# POC Kubernetes — Pipeline CI/CD com DevSecOps e Observabilidade

Prova de conceito de uma esteira completa de build, analise de qualidade, varredura de
vulnerabilidades, publicacao em registry privado, deploy em Kubernetes com Helm e
observabilidade de metricas e logs.

## Visao geral

O repositorio entrega uma aplicacao Flask containerizada, publicada em um Nexus privado
por um pipeline Jenkins declarativo, implantada em um cluster kind por Helm com rollback
atomico, e observada por Prometheus e Loki. O hardening do pod e verificado por script, e
uma politica Kyverno bloqueia imagens com tag `:latest`.

## Arquitetura
