# Kagenti Workload Harness

This repository contains workload harnesses for driving test and evaluation traffic to Kagenti agents.

## Current Scope

- **AppWorld harness** (`appworld_a2a_runner/`) — the first supported workload driver.
- **Exgentic harness** (`exgentic_a2a_runner/`) — drives Exgentic benchmarks (tau2, gsm8k, appworld) against Kagenti agents via A2A protocol.
- Designed to expand to additional workload drivers over time.

## Purpose

The workload harness exists to robustly exercise agents and validate that the Kagenti platform is:

- Reliable
- Scalable
- Observable
