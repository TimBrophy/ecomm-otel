# ── Universal Profiling dashboard ─────────────────────────────────────────────
#
# Replicates the core views that Datadog Continuous Profiler and Grafana
# Pyroscope show: top processes by CPU samples and CPU activity over time.
# Flame graphs are native to the Kibana Universal Profiling UI and are linked
# from the markdown panel rather than embedded here.
#
# Data source: profiling-events-all
# Key fields:  Count (sample count per stacktrace), process.name, host.name

locals {
  profiling_ds_json = jsonencode({
    type          = "data_view_spec"
    index_pattern = "profiling-events-all"
    time_field    = "@timestamp"
  })
}

resource "elasticstack_kibana_dashboard" "profiling_overview" {
  title       = "Universal Profiling — CPU Hotspots"
  description = "Top processes and CPU activity over time. Mirrors Datadog Continuous Profiler and Pyroscope views."

  time_range = {
    from = "now-1h"
    to   = "now"
  }

  refresh_interval = {
    pause = false
    value = 30000
  }

  query = {
    language = "kql"
    text     = ""
  }

  tags         = ["profiling", "uc1", "demo"]
  pinned_panels = []

  panels = [

    # ── Row 0: Header ─────────────────────────────────────────────────────────

    {
      type = "markdown"
      grid = { x = 0, y = 0, w = 48, h = 3 }
      markdown_config = {
        by_value = {
          content = "## Universal Profiling — CPU Hotspots\nContinuous profiling data from the EC2 profiling host running Elastic Agent. Shows which processes consume the most CPU — no code changes required.\n\n**[→ Open Flame Graph in Universal Profiling UI](/app/profiling)**"
          settings = { open_links_in_new_tab = true }
        }
      }
    },

    # ── Row 1: KPIs ───────────────────────────────────────────────────────────

    {
      type = "vis"
      grid = { x = 0, y = 3, w = 16, h = 5 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "Total CPU Samples"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM profiling-events-all | STATS total = SUM(`Count`)"
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
      grid = { x = 16, y = 3, w = 16, h = 5 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "Unique Processes"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM profiling-events-all | STATS total = COUNT_DISTINCT(`process.name`)"
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
      grid = { x = 32, y = 3, w = 16, h = 5 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "Profiled Hosts"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM profiling-events-all | STATS total = COUNT_DISTINCT(`host.name`)"
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

    # ── Row 2: CPU activity over time + Top processes ─────────────────────────

    {
      type = "vis"
      grid = { x = 0, y = 8, w = 28, h = 14 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title = "CPU Sample Rate Over Time"
            axis = {
              y = {
                domain_json = jsonencode({ type = "fit" })
                title       = { value = "CPU samples / bucket", visible = true }
              }
              x = { title = { value = "Time", visible = false } }
            }
            decorations = {}
            fitting     = { type = "none" }
            legend      = { is_visible = true, position = "bottom" }
            layers = [{
              type = "line"
              data_layer = {
                data_source_json = local.profiling_ds_json
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
                    operation     = "sum"
                    field         = "Count"
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
      grid = { x = 28, y = 8, w = 20, h = 14 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "Top Processes by CPU Samples"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM profiling-events-all | STATS cpu_samples = SUM(`Count`) BY process_name = `process.name` | SORT cpu_samples DESC | LIMIT 15"
              })
              styling = { density = { mode = "default" } }
              metrics = [{
                config_json = jsonencode({ operation = "value", column = "cpu_samples" })
              }]
            }
          }
        }
      }
    },

    # ── Row 3: Top hosts + incident correlation ───────────────────────────────

    {
      type = "vis"
      grid = { x = 0, y = 22, w = 24, h = 10 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "CPU Samples by Host"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM profiling-events-all | STATS cpu_samples = SUM(`Count`) BY host_name = `host.name` | SORT cpu_samples DESC | LIMIT 10"
              })
              styling = { density = { mode = "default" } }
              metrics = [{
                config_json = jsonencode({ operation = "value", column = "cpu_samples" })
              }]
            }
          }
        }
      }
    },

    {
      type = "vis"
      grid = { x = 24, y = 22, w = 24, h = 10 }
      vis_config = {
        by_value = {
          datatable_config = {
            esql = {
              title = "CPU Samples by Container"
              data_source_json = jsonencode({
                type  = "esql"
                query = "FROM profiling-events-all | WHERE `container.name` IS NOT NULL | STATS cpu_samples = SUM(`Count`) BY container_name = `container.name` | SORT cpu_samples DESC | LIMIT 10"
              })
              styling = { density = { mode = "default" } }
              metrics = [{
                config_json = jsonencode({ operation = "value", column = "cpu_samples" })
              }]
            }
          }
        }
      }
    },

    # ── Row 4: Flame graph nav ────────────────────────────────────────────────

    {
      type = "markdown"
      grid = { x = 0, y = 32, w = 48, h = 4 }
      markdown_config = {
        by_value = {
          content = "### Dive Deeper\n| View | Link |\n|---|---|\n| **Flame Graph** — full call-stack visualisation | [Open →](/app/profiling/flamegraph) |\n| **Top Functions** — ranked by CPU time with file/line | [Open →](/app/profiling/functions) |\n| **Differential Flame Graph** — compare before/after incident | [Open →](/app/profiling/flamegraph) |"
          settings = { open_links_in_new_tab = true }
        }
      }
    },

  ]
}
