# Fleet agent policy provisioning was attempted via REST API in scripts/demo.sh
# but removed in favour of a standalone EDOT collector that handles both OTLP
# ingestion and host metrics (hostmetrics receiver + resourcedetection/system).
#
# Key reason: Fleet enrollment adds apply-flow complexity (token management,
# pre-flight checks) with no demo payoff — the otlp_input_otel integration that
# motivated Fleet requires Agent OTel mode, incompatible with standard enrollment.
