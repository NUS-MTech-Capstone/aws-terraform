locals {
  test_app_name = "${var.name}-ok-${var.env}"
  test_alb_name = substr("${var.name}-${var.env}-ok", 0, 32)
}

resource "kubernetes_config_map_v1" "ok_nginx" {
  metadata {
    name      = "${local.test_app_name}-nginx"
    namespace = "default"
  }

  data = {
    "default.conf" = <<-EOT
      server {
        listen 80 default_server;
        server_name _;

        location / {
          default_type text/plain;
          return 200 "OK\n";
        }
      }
    EOT
  }

  depends_on = [module.eks]
}

resource "kubernetes_deployment_v1" "ok" {
  metadata {
    name      = local.test_app_name
    namespace = "default"

    labels = {
      app = local.test_app_name
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = local.test_app_name
      }
    }

    template {
      metadata {
        labels = {
          app = local.test_app_name
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:1.27-alpine"

          port {
            container_port = 80
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
          }
        }

        volume {
          name = "nginx-config"

          config_map {
            name = kubernetes_config_map_v1.ok_nginx.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "ok" {
  metadata {
    name      = local.test_app_name
    namespace = "default"
  }

  spec {
    selector = {
      app = local.test_app_name
    }

    port {
      name        = "http"
      port        = 80
      target_port = 80
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "ok" {
  metadata {
    name      = local.test_app_name
    namespace = "default"

    annotations = {
      "alb.ingress.kubernetes.io/load-balancer-name" = local.test_alb_name
      "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/listen-ports"       = "[{\"HTTP\":80}]"
      "alb.ingress.kubernetes.io/healthcheck-path"   = "/"
      "alb.ingress.kubernetes.io/success-codes"      = "200"
    }
  }

  spec {
    ingress_class_name = "alb"

    default_backend {
      service {
        name = kubernetes_service_v1.ok.metadata[0].name

        port {
          number = 80
        }
      }
    }
  }

  depends_on = [
    helm_release.alb_controller,
    kubernetes_deployment_v1.ok
  ]
}
