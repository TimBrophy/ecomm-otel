# ── Product Team Kibana provider alias ────────────────────────────────────────
#
# Points at the product team's own Serverless project.
# Credentials are set by `demo.sh provision-product-team` and passed in as
# TF_VAR_ environment variables before the targeted apply that creates this
# dashboard.

provider "elasticstack" {
  alias = "product_team"
  elasticsearch {
    endpoints = [var.product_team_es_endpoint]
    api_key   = var.product_team_api_key
  }
  kibana {
    endpoints = [var.product_team_kibana_endpoint]
    api_key   = var.product_team_api_key
  }
}

# ── Local data-source helpers ──────────────────────────────────────────────────
#
# All panels query the platform project via CPS.
# The inline data_view_spec with a "platform:" prefix routes agg queries
# through cross-project search transparently.

locals {
  pt_index   = "traces-generic.otel-default"
  pt_ds_json = jsonencode({
    type          = "data_view_spec"
    index_pattern = "traces-generic.otel-default"
    time_field    = "@timestamp"
  })

  checkout_kql = "resource.attributes.service.name: \"checkout-service\" AND span.name: \"POST /checkout\""
  order_kql    = "resource.attributes.service.name: \"order-service\" AND span.name: \"POST /orders\""
}

# ── Dashboard ─────────────────────────────────────────────────────────────────

resource "elasticstack_kibana_dashboard" "product_team_overview" {
  provider = elasticstack.product_team
  count    = var.product_team_kibana_endpoint != "" ? 1 : 0

  title = "Checkout Business Overview"
  description  = "Checkout throughput, order volume, and fraud detection impact — no p99 required."

  time_range = {
    from = "now-24h"
    to   = "now"
  }

  refresh_interval = {
    pause = false
    value = 60000
  }

  query = {
    language = "kql"
    text     = ""
  }

  tags = ["product-team", "checkout", "business"]

  pinned_panels = []

  panels = [

    # ── Row 0: Header ────────────────────────────────────────────────────────

    {
      type = "markdown"
      grid = { x = 0, y = 0, w = 48, h = 3 }
      markdown_config = {
        by_value = {
          content = "## Checkout Business Overview\nReal-time view of checkout funnel health across all services. Data via Cross-Project Search from the platform observability project."
          settings = {
            open_links_in_new_tab = false
          }
        }
      }
    },

    # ── Row 1: KPIs (y=3, h=5) ───────────────────────────────────────────────

    {
      type = "vis"
      grid = { x = 0, y = 3, w = 12, h = 5 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "Checkouts"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM traces-generic.otel-default | WHERE `resource.attributes.service.name` == \"checkout-service\" AND `span.name` == \"POST /checkout\" | STATS total = COUNT(*)"
              })
              styling = { density = { mode = "compact" } }
              metrics = [{
                config_json = jsonencode({ operation = "value", column = "total" })
              }]
            }
          }
        }
      }
    },

    {
      type = "vis"
      grid = { x = 12, y = 3, w = 12, h = 5 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "Avg Checkout Time (ms)"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM traces-generic.otel-default | WHERE `resource.attributes.service.name` == \"checkout-service\" AND `span.name` == \"POST /checkout\" | STATS avg_ms = ROUND(AVG(`duration`) / 1000000, 0)"
              })
              styling = { density = { mode = "compact" } }
              metrics = [{
                config_json = jsonencode({ operation = "value", column = "avg_ms" })
              }]
            }
          }
        }
      }
    },

    {
      type = "vis"
      grid = { x = 24, y = 3, w = 12, h = 5 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "Orders Fulfilled"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM traces-generic.otel-default | WHERE `resource.attributes.service.name` == \"order-service\" AND `span.name` == \"POST /orders\" | STATS total = COUNT(*)"
              })
              styling = { density = { mode = "compact" } }
              metrics = [{
                config_json = jsonencode({ operation = "value", column = "total" })
              }]
            }
          }
        }
      }
    },

    {
      type = "vis"
      grid = { x = 36, y = 3, w = 12, h = 5 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "P95 Checkout Latency (ms)"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM traces-generic.otel-default | WHERE `resource.attributes.service.name` == \"checkout-service\" AND `span.name` == \"POST /checkout\" | STATS p95_ms = ROUND(PERCENTILE(`duration`, 95) / 1000000, 0)"
              })
              styling = { density = { mode = "compact" } }
              metrics = [{
                config_json = jsonencode({ operation = "value", column = "p95_ms" })
              }]
            }
          }
        }
      }
    },

    # ── Row 2: Time series (y=8, h=12) ───────────────────────────────────────

    {
      type = "vis"
      grid = { x = 0, y = 8, w = 24, h = 12 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title = "Checkout Throughput"
            query = { expression = "resource.attributes.service.name: \"checkout-service\" AND span.name: \"POST /checkout\"" }
            axis = {
              y = {
                domain_json = jsonencode({ type = "fit" })
                title       = { value = "Requests / bucket", visible = true }
              }
              x = { title = { value = "Time", visible = false } }
            }
            decorations = {}
            fitting     = { type = "none" }
            legend      = { is_visible = true, position = "bottom" }
            layers = [{
              type = "line"
              data_layer = {
                data_source_json = local.pt_ds_json
                x_json = jsonencode({
                  operation               = "date_histogram"
                  field                   = "@timestamp"
                  suggested_interval      = "auto"
                  use_original_time_range = false
                  include_empty_rows      = true
                  drop_partial_intervals  = false
                })
                y = [{
                  config_json = jsonencode({
                    operation     = "count"
                    empty_as_null = false
                    format        = { type = "number", decimals = 0 }
                  })
                }]
              }
            }]
          }
        }
      }
    },

    {
      type = "vis"
      grid = { x = 24, y = 8, w = 24, h = 12 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title = "Avg Checkout Latency (ns)"
            query = { expression = "resource.attributes.service.name: \"checkout-service\" AND span.name: \"POST /checkout\"" }
            axis = {
              y = {
                domain_json = jsonencode({ type = "fit" })
                title       = { value = "Duration (ns)", visible = true }
              }
              x = { title = { value = "Time", visible = false } }
            }
            decorations = {}
            fitting     = { type = "none" }
            legend      = { is_visible = true, position = "bottom" }
            layers = [{
              type = "line"
              data_layer = {
                data_source_json = local.pt_ds_json
                x_json = jsonencode({
                  operation               = "date_histogram"
                  field                   = "@timestamp"
                  suggested_interval      = "auto"
                  use_original_time_range = false
                  include_empty_rows      = false
                  drop_partial_intervals  = false
                })
                y = [{
                  config_json = jsonencode({
                    operation = "average"
                    field     = "duration"
                  })
                }]
              }
            }]
          }
        }
      }
    },

    # ── Row 3: Breakdowns (y=20, h=10) ───────────────────────────────────────
    # Using datatable_config.esql — avoids terms x_json schema ambiguity and
    # gives clean sortable tables showing the categorical breakdown data.

    {
      type = "vis"
      grid = { x = 0, y = 20, w = 24, h = 10 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "Fraud Detection: Avg Latency by Flag State (ms)"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM traces-generic.otel-default | WHERE `resource.attributes.service.name` == \"checkout-service\" AND `span.name` == \"POST /checkout\" | STATS avg_ms = ROUND(AVG(`duration`) / 1000000, 0) BY flag_state = `attributes.feature_flag.realtime_fraud_detection` | SORT avg_ms DESC"
              })
              styling = { density = { mode = "default" } }
              metrics = [{
                config_json = jsonencode({ operation = "value", column = "avg_ms" })
              }]
            }
          }
        }
      }
    },

    {
      type = "vis"
      grid = { x = 24, y = 20, w = 24, h = 10 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "Request Volume by Service"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM traces-generic.otel-default | WHERE `resource.attributes.service.name` IN (\"api-gateway\", \"checkout-service\", \"order-service\", \"notification-service\") | STATS requests = COUNT(*) BY service = `resource.attributes.service.name` | SORT requests DESC"
              })
              styling = { density = { mode = "default" } }
              metrics = [{
                config_json = jsonencode({ operation = "value", column = "requests" })
              }]
            }
          }
        }
      }
    },

  ]
}
