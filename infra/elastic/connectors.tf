# Slack connector is provisioned via the Kibana REST API in scripts/demo.sh
# (provision_slack_connector) rather than Terraform, because the ec_api_key
# used by the elasticstack provider does not have Kibana action connector
# privileges on Serverless projects.
