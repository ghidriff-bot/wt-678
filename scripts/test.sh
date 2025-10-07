#!/usr/bin/env bash
set -u  # Treat unset variables as an error

test_func() {
  local pattern_args=()

  # Uncomment this line to simulate adding an argument
  pattern_args=(--pattern "foo")

  echo "Running command with safe expansion..."
  echo cmd ${pattern_args[@]+"${pattern_args[@]}"} end
}

test_func
