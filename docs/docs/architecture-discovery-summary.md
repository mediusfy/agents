# Orgitration Architecture Summary

## The System Itself
- **Type**: Single-process Python Multi-Agent SDLC system (NOT microservices)
- **Image**: `python:3.12-slim-bookworm` base
- **MCP Ports**: 8080 (full), 8002 (slim)
- **Deployment**: Docker Compose only (no Helm/K8s/Terraform exist yet)
- **External Deps**: LLM APIs (OpenAI, Anthropic, Gemini, DeepSeek)

## What It Generates
- Go microservices (hexagonal architecture) + Vue frontend + PostgreSQL
- Target format: `cmd/<service>/main.go`, `internal/{domain,application,ports,adapters}/`
- Communication: gRPC + CloudEvents between services
- Infra: SRE agent produces Helm/K8s/Terraform

## Current Generated Output Status
- generated-app/default/ contains only empty stubs
- No real business logic, Dockerfiles, go.mod, or Terraform resources exist yet
