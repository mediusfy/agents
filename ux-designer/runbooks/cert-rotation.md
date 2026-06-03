# TLS Certificate Rotation Runbook

> **Symptom:** Ingress returning 526 (invalid SSL certificate)
> **Diagnosis:** Certificate expires in < 7 days
> **Mitigation:** Trigger cert-manager renewal, verify new cert
> **Investigation:** Check certificate expiry, review renewal policy
> **Prevention:** Set up cert-manager with auto-renewal 30 days before expiry

## 1. Check Certificate Expiry

```sh
kubectl get certificate -n istio-system -o wide | head -20
```

## 2. Describe Expiring Certificate

```sh
kubectl describe certificate -n istio-system <cert-name> | grep -E "Not After|Renewal"
```

## 3. Trigger Manual Renewal

```sh
kubectl delete secret -n istio-system <cert-secret-name>
kubectl annotate certificate -n istio-system <cert-name> cert-manager.io/issue-temporary-certificate=true
```

## 4. Verify New Certificate

```sh
kubectl get certificate -n istio-system -o wide | grep <cert-name>
kubectl describe certificate -n istio-system <cert-name> | grep -E "Not After|Ready"
```
