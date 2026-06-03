# Redis Pod Failover Runbook

> **Symptom:** Redis pods in CrashLoopBackOff after OOMKilled
> **Diagnosis:** Memory limit (64Mi) insufficient for current traffic pattern
> **Mitigation:** Increase memory limit and rolling restart
> **Investigation:** Check memory usage patterns, review recent traffic increases
> **Prevention:** Set up HPA based on memory usage, add memory limit alerts

## 1. Check Redis Pod Status

```kubectl
kubectl get pods -n redis -l app=redis
```

## 2. Describe Failing Pod

```sh
kubectl describe pod -n redis -l app=redis | grep -A10 "State:"
```

## 3. Check Memory Usage

```sh
kubectl top pod -n redis -l app=redis --containers
```

## 4. Increase Memory Limit

Apply the updated resource limits:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
  namespace: redis
spec:
  template:
    spec:
      containers:
      - name: redis
        resources:
          limits:
            memory: 256Mi
          requests:
            memory: 128Mi
```

## 5. Rolling Restart

```sh
kubectl rollout restart statefulset/redis -n redis
```

## 6. Verify Recovery

```sh
kubectl get pods -n redis -l app=redis -w
```
