"""Configuration management for Exgentic A2A Runner.

Configuration is loaded from environment variables with optional CLI overrides.
"""

import os
from dataclasses import dataclass
from typing import Optional


def _get_bool(key: str, default: bool = False) -> bool:
    """Get boolean value from environment variable."""
    value = os.getenv(key, "").lower()
    if value in ("1", "true", "yes", "on"):
        return True
    elif value in ("0", "false", "no", "off"):
        return False
    return default


def _get_int(key: str, default: Optional[int] = None) -> Optional[int]:
    """Get integer value from environment variable."""
    value = os.getenv(key)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError:
        return default


@dataclass
class ExgenticConfig:
    """Exgentic MCP server configuration."""

    mcp_server_url: str
    mcp_timeout_seconds: int = 60
    mcp_tool_prefix: str = ""
    max_tasks: Optional[int] = None
    abort_on_failure: bool = False
    max_parallel_sessions: int = 1
    benchmark_name: str = "unknown"
    agent_name: str = "unknown"
    experiment_name: str = "default"

    @classmethod
    def from_env(cls) -> "ExgenticConfig":
        """Load Exgentic configuration from environment variables."""
        mcp_server_url = os.getenv("EXGENTIC_MCP_SERVER_URL")
        if not mcp_server_url:
            raise ValueError("EXGENTIC_MCP_SERVER_URL environment variable is required")

        return cls(
            mcp_server_url=mcp_server_url,
            mcp_timeout_seconds=_get_int("EXGENTIC_MCP_TIMEOUT_SECONDS", 60) or 60,
            mcp_tool_prefix=os.getenv("EXGENTIC_MCP_TOOL_PREFIX", ""),
            max_tasks=_get_int("MAX_TASKS"),
            abort_on_failure=_get_bool("ABORT_ON_FAILURE", False),
            max_parallel_sessions=_get_int("MAX_PARALLEL_SESSIONS", 1) or 1,
            benchmark_name=os.getenv("BENCHMARK_NAME", "unknown"),
            agent_name=os.getenv("AGENT_NAME", "unknown"),
            experiment_name=os.getenv("EXPERIMENT_NAME", "default"),
        )


@dataclass
class A2AConfig:
    """A2A endpoint configuration."""

    base_url: str
    timeout_seconds: int = 300
    auth_token: Optional[str] = None
    verify_tls: bool = True
    endpoint_path: str = "/v1/chat"

    @classmethod
    def from_env(cls) -> "A2AConfig":
        """Load A2A configuration from environment variables."""
        base_url = os.getenv("A2A_BASE_URL")
        if not base_url:
            raise ValueError("A2A_BASE_URL environment variable is required")

        return cls(
            base_url=base_url,
            timeout_seconds=_get_int("A2A_TIMEOUT_SECONDS", 300) or 300,
            auth_token=os.getenv("A2A_AUTH_TOKEN"),
            verify_tls=_get_bool("A2A_VERIFY_TLS", True),
            endpoint_path=os.getenv("A2A_ENDPOINT_PATH", "/"),
        )


@dataclass
class OTELConfig:
    """OpenTelemetry configuration."""

    service_name: str = "exgentic-a2a-runner"
    exporter_endpoint: Optional[str] = None
    exporter_protocol: str = "grpc"
    resource_attributes: Optional[str] = None
    instrument_requests: bool = True
    exporter_insecure: bool = True

    @classmethod
    def from_env(cls) -> "OTELConfig":
        """Load OTEL configuration from environment variables."""
        return cls(
            service_name=os.getenv("OTEL_SERVICE_NAME", "exgentic-a2a-runner"),
            exporter_endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
            exporter_protocol=os.getenv("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc"),
            resource_attributes=os.getenv("OTEL_RESOURCE_ATTRIBUTES"),
            instrument_requests=_get_bool("OTEL_INSTRUMENT_REQUESTS", True),
            exporter_insecure=_get_bool("OTEL_EXPORTER_OTLP_INSECURE", True),
        )


@dataclass
class PrometheusConfig:
    """Prometheus metrics collection configuration."""

    url: Optional[str] = None
    namespace: str = "team1"
    mcp_pod_prefix: Optional[str] = None
    a2a_pod_prefix: Optional[str] = None

    @property
    def enabled(self) -> bool:
        return bool(self.url and self.mcp_pod_prefix and self.a2a_pod_prefix)

    @classmethod
    def from_env(cls) -> "PrometheusConfig":
        """Load Prometheus configuration from environment variables."""
        return cls(
            url=os.getenv("PROMETHEUS_URL"),
            namespace=os.getenv("INFRA_NAMESPACE", "team1"),
            mcp_pod_prefix=os.getenv("INFRA_MCP_POD_PREFIX"),
            a2a_pod_prefix=os.getenv("INFRA_A2A_POD_PREFIX"),
        )


@dataclass
class DebugConfig:
    """Debug and logging configuration."""

    log_prompt: bool = False
    log_response: bool = False

    @classmethod
    def from_env(cls) -> "DebugConfig":
        """Load debug configuration from environment variables."""
        return cls(
            log_prompt=_get_bool("LOG_PROMPT", False),
            log_response=_get_bool("LOG_RESPONSE", False),
        )


@dataclass
class Config:
    """Complete runner configuration."""

    exgentic: ExgenticConfig
    a2a: A2AConfig
    otel: OTELConfig
    prometheus: PrometheusConfig
    debug: DebugConfig

    @classmethod
    def from_env(cls) -> "Config":
        """Load complete configuration from environment variables."""
        return cls(
            exgentic=ExgenticConfig.from_env(),
            a2a=A2AConfig.from_env(),
            otel=OTELConfig.from_env(),
            prometheus=PrometheusConfig.from_env(),
            debug=DebugConfig.from_env(),
        )


