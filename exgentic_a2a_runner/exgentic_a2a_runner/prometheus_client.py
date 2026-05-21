"""Prometheus client for collecting container infrastructure metrics.

Queries Prometheus for CPU, memory, network, and throttling metrics
for MCP and A2A pods during a session's time window.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Optional

import requests

logger = logging.getLogger(__name__)


@dataclass
class PodMetrics:
    """Infrastructure metrics for a single pod over a time window."""

    cpu_utilization_pct: float = 0.0
    cpu_limit_cores: float = 0.0
    throttle_pct: float = 0.0
    memory_max_mb: float = 0.0
    memory_limit_mb: float = 0.0
    memory_utilization_pct: float = 0.0
    network_rx_mb: float = 0.0
    network_tx_mb: float = 0.0


class PrometheusMetricsCollector:
    """Collect container metrics from Prometheus for MCP and A2A pods."""

    def __init__(
        self,
        prometheus_url: str,
        namespace: str,
        mcp_pod_prefix: str,
        a2a_pod_prefix: str,
    ):
        self._url = prometheus_url.rstrip("/")
        self._namespace = namespace
        self._pod_configs = {
            "mcp": mcp_pod_prefix,
            "a2a": a2a_pod_prefix,
        }
        self._timeout = 5.0

    def _query_instant(self, promql: str, ts: float) -> Optional[float]:
        """Execute an instant query at a specific timestamp. Returns scalar or first result."""
        try:
            resp = requests.get(
                f"{self._url}/api/v1/query",
                params={"query": promql, "time": ts},
                timeout=self._timeout,
            )
            resp.raise_for_status()
            data = resp.json()
            results = data.get("data", {}).get("result", [])
            if results:
                return float(results[0]["value"][1])
        except Exception as e:
            logger.warning("Prometheus query failed: %s (query: %s)", e, promql)
        return None

    def _pod_selector(self, pod_prefix: str) -> str:
        """Build the common label selector for a pod."""
        return f'namespace="{self._namespace}", pod=~"{pod_prefix}.*"'

    def _collect_pod_metrics(self, pod_prefix: str, start: float, end: float) -> PodMetrics:
        """Collect all metrics for a single pod."""
        sel = self._pod_selector(pod_prefix)
        # Ensure window is at least 60s so increase()/max_over_time() have
        # enough data points (Prometheus scrape interval is typically 15-30s,
        # need at least 2 scrapes for increase() to compute a delta).
        duration = max(int(end - start), 1)

        # CPU usage as average utilization % of limit over the window
        # rate() gives per-second CPU usage, quota/period gives the limit in cores
        cpu_seconds = self._query_instant(
            f'sum(increase(container_cpu_usage_seconds_total{{{sel}}}[{duration}s]))', end
        ) or 0.0

        # CPU limit in cores (quota / period, e.g. 400000/100000 = 4 cores)
        cpu_quota = self._query_instant(f'max(container_spec_cpu_quota{{{sel}}})', end)
        cpu_period = self._query_instant(f'max(container_spec_cpu_period{{{sel}}})', end)
        cpu_limit_cores = (cpu_quota / cpu_period) if cpu_quota and cpu_period and cpu_period > 0 else 0.0

        # Utilization % = (cpu_seconds used / (duration * limit_cores)) * 100
        wall_seconds = max(end - start, 1)
        cpu_utilization_pct = (cpu_seconds / (wall_seconds * cpu_limit_cores) * 100.0) if cpu_limit_cores > 0 else 0.0

        # CPU throttling — pod-level (no container label needed)
        throttled = self._query_instant(
            f'sum(increase(container_cpu_cfs_throttled_periods_total{{{sel}}}[{duration}s]))', end
        ) or 0.0
        total_periods = self._query_instant(
            f'sum(increase(container_cpu_cfs_periods_total{{{sel}}}[{duration}s]))', end
        ) or 0.0
        throttle_pct = (throttled / total_periods * 100.0) if total_periods > 0 else 0.0

        # Memory — max working set across the window (take the max across containers)
        memory_bytes = self._query_instant(
            f'max(max_over_time(container_memory_working_set_bytes{{{sel}}}[{duration}s]))', end
        ) or 0.0
        memory_max_mb = memory_bytes / (1024 * 1024)

        # Memory limit
        memory_limit_bytes = self._query_instant(
            f'max(container_spec_memory_limit_bytes{{{sel}}})', end
        ) or 0.0
        memory_limit_mb = memory_limit_bytes / (1024 * 1024) if memory_limit_bytes > 0 else 0.0
        memory_utilization_pct = (memory_bytes / memory_limit_bytes * 100.0) if memory_limit_bytes > 0 else 0.0

        # Network — pod-level (attached to pause container), use increase()
        network_rx = self._query_instant(
            f'sum(increase(container_network_receive_bytes_total{{{sel}}}[{duration}s]))', end
        ) or 0.0
        network_tx = self._query_instant(
            f'sum(increase(container_network_transmit_bytes_total{{{sel}}}[{duration}s]))', end
        ) or 0.0

        metrics = PodMetrics(
            cpu_utilization_pct=round(cpu_utilization_pct, 1),
            cpu_limit_cores=round(cpu_limit_cores, 2),
            throttle_pct=round(throttle_pct, 1),
            memory_max_mb=round(memory_max_mb, 1),
            memory_limit_mb=round(memory_limit_mb, 1),
            memory_utilization_pct=round(memory_utilization_pct, 1),
            network_rx_mb=round(network_rx / (1024 * 1024), 3) if network_rx else 0.0,
            network_tx_mb=round(network_tx / (1024 * 1024), 3) if network_tx else 0.0,
        )
        logger.info(
            "Pod %s metrics: cpu=%.1f%% throttle=%.1f%% mem=%.1fMB/%.1fMB(%.1f%%) "
            "net_rx=%.3fMB net_tx=%.3fMB (window=%ds)",
            pod_prefix, cpu_utilization_pct, throttle_pct,
            memory_max_mb, memory_limit_mb, memory_utilization_pct,
            metrics.network_rx_mb, metrics.network_tx_mb, duration,
        )
        return metrics

    def collect_session_metrics(
        self, start_time: float, end_time: float
    ) -> dict[str, PodMetrics]:
        """Collect metrics for all configured pods over a time window.

        Args:
            start_time: Unix timestamp of session start
            end_time: Unix timestamp of session end

        Returns:
            Dict mapping pod key ("mcp", "a2a") to PodMetrics
        """
        results = {}
        for pod_key, pod_prefix in self._pod_configs.items():
            try:
                metrics = self._collect_pod_metrics(pod_prefix, start_time, end_time)
                results[pod_key] = metrics
            except Exception as e:
                logger.warning("Failed to collect %s metrics: %s", pod_key, e)
                results[pod_key] = PodMetrics()
        return results

    def check_connectivity(self) -> bool:
        """Check if Prometheus is reachable."""
        try:
            resp = requests.get(
                f"{self._url}/api/v1/status/config",
                timeout=self._timeout,
            )
            return resp.status_code == 200
        except Exception:
            return False
