#!/bin/bash

profile_deployment_compose() {
  profile_basic
  run_docker
  run_provision_servers_extension
}
