# OpenBao Component

This component deploys OpenBao, an open-source secrets management system, to the Kubernetes cluster.

## Overview

OpenBao is a fork of HashiCorp Vault, providing secure, reliable secrets management for cloud-native applications. It offers:

- **Secret Storage**: Securely store and manage sensitive data like passwords, API keys, and certificates
- **Dynamic Secrets**: Generate short-lived credentials for databases and cloud services
- **Encryption as a Service**: Provide encryption capabilities to applications without exposing encryption keys
- **Authentication & Authorization**: Multiple auth methods and fine-grained access control
- **Audit Logging**: Comprehensive audit trail of all operations

## Configuration Files

- `source.yaml`: Defines the OpenBao Helm chart source
- `default-values.yaml`: Default configuration for OpenBao deployment
- `values.yaml`: Project-specific overrides and customizations

## Default Configuration

The default configuration includes:

- **High Availability**: 3-replica deployment with Raft storage
- **Security**: Non-root container execution and secure defaults
- **Storage**: 10Gi persistent volumes for data and audit logs
- **Monitoring**: ServiceMonitor for Prometheus integration
- **UI**: Web interface enabled for management
- **Injector**: Automatic secret injection into pods
- **CSI**: Secret Store CSI driver for file-based secret injection

## Integration with External Secrets

OpenBao is designed to work with the External Secrets Operator in ClusterForge. You can configure External Secrets to use OpenBao as a backend by creating a SecretStore or ClusterSecretStore resource.

## Deployment Order

OpenBao is deployed with `syncwave: -10` to ensure it starts before other components that may depend on it for secrets management.

## Customization

Modify `values.yaml` to customize the deployment for your specific requirements:

- Storage classes and sizes
- Resource limits and requests
- Ingress configuration
- TLS settings
- Authentication methods

## Post-Deployment

After deployment, you'll need to:

1. Initialize OpenBao
2. Unseal the vault (unless using auto-unseal)
3. Configure authentication methods
4. Set up policies and secrets

Refer to the OpenBao documentation for detailed configuration steps.
