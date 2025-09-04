
---

### 📄 `docs/INSTALLATION.md`
Step-by-step setup reference (expanded version of README quick start).

```markdown
# Installation Guide

This document provides a detailed walkthrough of setting up **OCM + ArgoCD** demo environments using the automation script.

## 1. Install Prerequisites
Ensure you have:
- Linux or macOS
- `docker`, `kind`, `kubectl`, `helm`, `cilium`, `clusteradm`


## 2. Clone and Run Setup Script
```bash
git clone https://github.com/RajivBB/argo-mc-starter.git
cd argo-mc-starter
chmod +x scripts/ocm-argo-setup.sh
./scripts/ocm-argo-setup.sh
