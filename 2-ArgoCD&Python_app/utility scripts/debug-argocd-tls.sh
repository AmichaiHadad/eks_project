#!/bin/bash
# Diagnoses and fixes HTTPS/TLS configuration issues for ArgoCD
#
# Checks:
# - TLS certificate secrets
# - Load balancer annotations
# - ArgoCD server configuration
# - SSL handshake validity
#
# Automatically applies fixes for:
# - Certificate mismatches
# - Service misconfigurations
# - Security policy issues
#
# Prerequisites:
# - OpenSSL installed
# - kubectl access to cluster
# - Bash 4.2+
#
# Usage:
# ./debug-argocd-tls.sh 