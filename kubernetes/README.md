# Rallly Kubernetes Manifests

This directory contains base Kubernetes manifests to self-host Rallly. It separates configuration (ConfigMaps) from sensitive data (Secrets) and uses a StatefulSet for the PostgreSQL database.

## Prerequisites

- A Kubernetes cluster.
- `kubectl` configured to talk to your cluster.
- An Ingress Controller (e.g., NGINX) installed.

## Configuration

1.  **Secrets (`secrets.yaml`):**
    - **Important:** Do not commit the `secrets.yaml` file with real credentials to version control.
    - Update `POSTGRES_PASSWORD` and `SECRET_PASSWORD` (use `openssl rand -hex 32` to generate).
    - Update `DATABASE_URL` to match your postgres password.

2.  **Config (`rallly-config.yaml`):**
    - Update `NEXT_PUBLIC_BASE_URL` to match your domain.
    - Configure your SMTP settings for emails.

3.  **Ingress (`ingress.yaml`):**
    - Change `host: rallly.example.com` to your actual domain.
    - Ensure `ingressClassName` matches your cluster's controller (default is set to `nginx`).

## Deployment Order

Apply the manifests in the following order to ensure dependencies are met:

```bash
# 1. Apply Secrets and Config first
kubectl apply -f secrets.yaml
kubectl apply -f rallly-config.yaml

# 2. Apply Database (StatefulSet)
kubectl apply -f postgres.yaml

# 3. Apply Application (Deployment)
kubectl apply -f rallly.yaml

# 4. Apply Ingress
kubectl apply -f ingress.yaml

# 5. Check that the pods are running - should show '1/1 Running' for each pod.
kubectl get pods
```
