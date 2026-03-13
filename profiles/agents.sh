#!/bin/bash

profile_agents() {
  profile_basic
  run_docker
  run_provision_servers_extension
  run_post_setup
}
