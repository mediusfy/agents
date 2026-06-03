# =============================================================================
# Crossplane Provider Configuration
# =============================================================================
# Declarative multi-region infrastructure provisioning via Crossplane
# =============================================================================

resource "helm_release" "crossplane" {
  name       = "crossplane"
  repository = "https://charts.crossplane.io/stable"
  chart      = "crossplane"
  version    = "~> 1.18"

  namespace        = "crossplane-system"
  create_namespace = true

  values = [
    <<-YAML
    args:
      - --enable-external-secret-stores
      - --enable-composition-revisions
      - --max-reconcile-rate=30
    features:
      enableCompositionFunctions: true
      enableRealtimeCompositions: true
    resourcesCrossplane:
      limits:
        cpu: "1"
        memory: "512Mi"
      requests:
        cpu: "500m"
        memory: "256Mi"
    provider:
      packages:
        - ${var.provider_aws_package}
        - ${var.provider_kubernetes_package}
        - ${var.provider_helm_package}
    YAML
  ]

  depends_on = [module.eks]
}

resource "kubernetes_secret" "aws_provider_creds" {
  metadata {
    name      = "aws-provider-creds"
    namespace = "crossplane-system"
  }

  data = {
    credentials = var.aws_credentials_json
  }

  type = "Opaque"
}

resource "crossplane_provider_config" "aws" {
  api_version = "aws.crossplane.io/v1beta1"
  kind        = "ProviderConfig"

  metadata = {
    name = "aws-provider"
  }

  spec = {
    credentials = {
      source = "Secret"
      secretRef = {
        name      = kubernetes_secret.aws_provider_creds.metadata[0].name
        namespace = "crossplane-system"
        key       = "credentials"
      }
    }
  }

  depends_on = [helm_release.crossplane]
}
