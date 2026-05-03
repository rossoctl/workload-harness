"""OpenTelemetry instrumentation for Exgentic A2A Runner.

Provides traces, metrics, and logs for monitoring session execution.
"""

import logging
import time
from contextlib import contextmanager
from typing import Iterator, Optional

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
from opentelemetry.trace import Status, StatusCode, SpanKind

from .config import OTELConfig

logger = logging.getLogger(__name__)


class OTELInstrumentation:
    """OpenTelemetry instrumentation manager."""

    def __init__(self, config: OTELConfig):
        """Initialize OTEL instrumentation.

        Args:
            config: OTEL configuration
        """
        self.config = config
        self.tracer: Optional[trace.Tracer] = None
        self.meter: Optional[metrics.Meter] = None
        self._trace_provider: Optional[TracerProvider] = None
        self._meter_provider: Optional[MeterProvider] = None

        # Metrics
        self.sessions_counter: Optional[metrics.Counter] = None
        self.errors_counter: Optional[metrics.Counter] = None
        self.session_latency_histogram: Optional[metrics.Histogram] = None
        self.evaluation_latency_histogram: Optional[metrics.Histogram] = None
        self.session_creation_latency_histogram: Optional[metrics.Histogram] = None
        self.a2a_latency_histogram: Optional[metrics.Histogram] = None
        self.prompt_size_histogram: Optional[metrics.Histogram] = None
        self.response_size_histogram: Optional[metrics.Histogram] = None
        self.inflight_sessions_gauge: Optional[metrics.UpDownCounter] = None
        self._requests_instrumented = False

    def initialize(self) -> None:
        """Initialize OTEL providers and instruments."""
        logger.info("Initializing OpenTelemetry instrumentation")

        # Create resource with service name and attributes
        resource_attrs = {"service.name": self.config.service_name}
        if self.config.resource_attributes:
            # Parse resource attributes (format: key1=val1,key2=val2)
            for attr in self.config.resource_attributes.split(","):
                if "=" in attr:
                    key, value = attr.split("=", 1)
                    resource_attrs[key.strip()] = value.strip()

        resource = Resource.create(resource_attrs)

        # Initialize tracing
        self._initialize_tracing(resource)

        # Initialize auto-instrumentation
        self._initialize_auto_instrumentation()

        # Initialize metrics
        self._initialize_metrics(resource)

        logger.info("OpenTelemetry instrumentation initialized")

    def _initialize_tracing(self, resource: Resource) -> None:
        """Initialize tracing provider and exporter."""
        trace_provider = TracerProvider(resource=resource)

        if self.config.exporter_endpoint:
            # Use OTLP exporter
            logger.info(f"Configuring OTLP trace exporter: {self.config.exporter_endpoint}")
            span_exporter = OTLPSpanExporter(
                endpoint=self.config.exporter_endpoint,
                insecure=self.config.exporter_insecure,
            )
            trace_provider.add_span_processor(BatchSpanProcessor(span_exporter))
        else:
            # No exporter configured - traces will be collected but not exported
            logger.info("No OTLP endpoint configured, traces will not be exported")

        trace.set_tracer_provider(trace_provider)
        self._trace_provider = trace_provider

        self.tracer = trace.get_tracer(__name__)

    def _initialize_auto_instrumentation(self) -> None:
        """Initialize opt-in auto instrumentation."""
        if not self.config.instrument_requests:
            logger.info("Requests auto-instrumentation disabled")
            return

        if self._requests_instrumented:
            return

        RequestsInstrumentor().instrument()
        self._requests_instrumented = True
        logger.info("Enabled OpenTelemetry requests auto-instrumentation")

    def _initialize_metrics(self, resource: Resource) -> None:
        """Initialize metrics provider and instruments."""
        metric_readers = []

        if self.config.exporter_endpoint:
            # Use OTLP exporter
            logger.info(f"Configuring OTLP metric exporter: {self.config.exporter_endpoint}")
            metric_exporter = OTLPMetricExporter(
                endpoint=self.config.exporter_endpoint,
                insecure=self.config.exporter_insecure,
            )
            metric_reader = PeriodicExportingMetricReader(metric_exporter)
            metric_readers.append(metric_reader)
        else:
            # No exporter configured - metrics will be collected but not exported
            logger.info("No OTLP endpoint configured, metrics will not be exported")

        meter_provider = MeterProvider(
            resource=resource,
            metric_readers=metric_readers,
        )
        metrics.set_meter_provider(meter_provider)
        self._meter_provider = meter_provider

        self.meter = metrics.get_meter(__name__)

        # Create metric instruments
        self.sessions_counter = self.meter.create_counter(
            name="exgentic_a2a_sessions_total",
            description="Total number of sessions processed",
            unit="1",
        )

        self.errors_counter = self.meter.create_counter(
            name="exgentic_a2a_errors_total",
            description="Total number of errors",
            unit="1",
        )

        self.session_latency_histogram = self.meter.create_histogram(
            name="exgentic_a2a_session_latency_seconds",
            description="Session processing latency in seconds",
            unit="s",
        )

        self.evaluation_latency_histogram = self.meter.create_histogram(
            name="exgentic_a2a_evaluation_latency_seconds",
            description="Session evaluation latency in seconds",
            unit="s",
        )

        self.session_creation_latency_histogram = self.meter.create_histogram(
            name="exgentic_a2a_session_creation_latency_seconds",
            description="Session creation latency in seconds",
            unit="s",
        )

        self.a2a_latency_histogram = self.meter.create_histogram(
            name="exgentic_a2a_a2a_latency_seconds",
            description="A2A request latency in seconds",
            unit="s",
        )

        self.prompt_size_histogram = self.meter.create_histogram(
            name="exgentic_a2a_prompt_size_chars",
            description="Prompt size in characters",
            unit="chars",
        )

        self.response_size_histogram = self.meter.create_histogram(
            name="exgentic_a2a_response_size_chars",
            description="Response size in characters",
            unit="chars",
        )

        self.inflight_sessions_gauge = self.meter.create_up_down_counter(
            name="exgentic_a2a_inflight_sessions",
            description="Number of sessions currently in flight",
            unit="1",
        )

    def shutdown(self) -> None:
        """Shut down OTEL providers to flush pending spans and metrics."""
        logger.info("Shutting down OpenTelemetry providers")
        if self._trace_provider:
            self._trace_provider.shutdown()
        if self._meter_provider:
            self._meter_provider.shutdown()

    @contextmanager
    def session_span(
        self,
        session_id: str,
        mcp_server_url: str,
        a2a_base_url: str,
        a2a_timeout: int,
        benchmark_name: str,
        agent_name: str,
        task_id: str,
        num_parallel_tasks: int,
        experiment_name: str = "default",
    ) -> Iterator[trace.Span]:
        """Create a span for session processing.

        Args:
            session_id: Session identifier
            mcp_server_url: MCP server URL
            a2a_base_url: A2A endpoint URL (sanitized)
            a2a_timeout: A2A timeout in seconds
            benchmark_name: Name of the benchmark being run
            agent_name: Name of the agent being tested
            task_id: Task identifier
            num_parallel_tasks: Number of parallel tasks configured
            experiment_name: Name of the experiment (for grouping/filtering runs)

        Yields:
            Span object for adding events and attributes
        """
        if not self.tracer:
            raise RuntimeError("OTEL not initialized")

        # Increment inflight gauge
        if self.inflight_sessions_gauge:
            self.inflight_sessions_gauge.add(1)

        start_time = time.time()

        with self.tracer.start_as_current_span(
            "Agent.Session",
            kind=SpanKind.INTERNAL
        ) as span:
            # Set span kind to CHAIN for OpenInference
            span.set_attribute("openinference.span.kind", "CHAIN")
            
            # Set span attributes
            span.set_attribute("metadata.session_id", session_id)
            span.set_attribute("metadata.mcp_server_url", mcp_server_url)
            span.set_attribute("metadata.a2a_url", a2a_base_url)
            span.set_attribute("metadata.timeout_seconds", a2a_timeout)
            
            # Set metadata attributes (using metadata. prefix for Arize Phoenix)
            span.set_attribute("metadata.benchmark_name", benchmark_name)
            span.set_attribute("metadata.agent_name", agent_name)
            span.set_attribute("metadata.task_id", task_id)
            span.set_attribute("metadata.num_parallel_tasks", num_parallel_tasks)
            span.set_attribute("metadata.experiment_name", experiment_name)

            try:
                yield span
            finally:
                # Decrement inflight gauge
                if self.inflight_sessions_gauge:
                    self.inflight_sessions_gauge.add(-1)

                # Record session latency
                latency_seconds = time.time() - start_time
                if self.session_latency_histogram:
                    self.session_latency_histogram.record(latency_seconds)

    @contextmanager
    def child_span(self, name: str, kind: Optional[SpanKind] = None) -> Iterator[trace.Span]:
        """Create a child span under the current context.
        
        Args:
            name: Span name
            kind: Optional span kind (e.g., SpanKind.INTERNAL, SpanKind.CLIENT)
        """
        if not self.tracer:
            raise RuntimeError("OTEL not initialized")

        kwargs = {"name": name}
        if kind is not None:
            kwargs["kind"] = kind
            
        with self.tracer.start_as_current_span(**kwargs) as span:
            yield span

    def record_prompt(self, span: trace.Span, prompt: str) -> None:
        """Record prompt information.

        Args:
            span: Current span
            prompt: Prompt text
        """
        prompt_chars = len(prompt)
        # Use OpenInference semantic conventions for LLM spans
        span.set_attribute("llm.input_messages", [{"message.content": prompt, "message.role": "user"}])
        span.set_attribute("input.value", prompt)
        span.set_attribute("input.mime_type", "text/plain")

        if self.prompt_size_histogram:
            self.prompt_size_histogram.record(prompt_chars)

    def record_a2a_request(
        self,
        span: trace.Span,
        duration_seconds: float,
    ) -> None:
        """Record A2A request metrics.

        Args:
            span: Current span
            duration_seconds: Request duration in seconds
        """
        span.set_attribute("metadata.agent_call_duration_seconds", duration_seconds)

        if self.a2a_latency_histogram:
            self.a2a_latency_histogram.record(duration_seconds)

    def record_response(self, span: trace.Span, response: str) -> None:
        """Record response information.

        Args:
            span: Current span
            response: Response text
        """
        response_chars = len(response)
        # Use OpenInference semantic conventions for LLM spans
        span.set_attribute("llm.output_messages", [{"message.content": response, "message.role": "assistant"}])
        span.set_attribute("output.value", response)
        span.set_attribute("output.mime_type", "text/plain")

        if self.response_size_histogram:
            self.response_size_histogram.record(response_chars)

    def record_success(self, span: trace.Span, evaluation_result: bool) -> None:
        """Record successful session completion.

        Args:
            span: Current span
            evaluation_result: Whether the session evaluation was successful
        """
        span.set_attribute("metadata.status", "success")
        span.set_attribute("metadata.evaluation_result", evaluation_result)
        span.set_status(Status(StatusCode.OK))

        if self.sessions_counter:
            self.sessions_counter.add(1, {"status": "success"})

    def record_failure(
        self,
        span: trace.Span,
        error: Exception,
        error_type: str,
    ) -> None:
        """Record session failure.

        Args:
            span: Current span
            error: Exception that caused failure
            error_type: Error type classification
        """
        span.set_attribute("metadata.status", "failed")
        span.add_event(
            "exception",
            attributes={
                "exception.type": error_type,
                "exception.message": str(error),
            },
        )
        span.set_status(Status(StatusCode.ERROR, str(error)))
        span.record_exception(error)

        if self.sessions_counter:
            self.sessions_counter.add(1, {"status": "failed"})

        if self.errors_counter:
            self.errors_counter.add(1, {"error_type": error_type})

    def record_evaluation(self, span: trace.Span, duration_seconds: float) -> None:
        """Record session evaluation metrics.

        Args:
            span: Current span
            duration_seconds: Evaluation duration in seconds
        """
        span.set_attribute("metadata.evaluation_duration_seconds", duration_seconds)

        if self.evaluation_latency_histogram:
            self.evaluation_latency_histogram.record(duration_seconds)

    def record_session_creation(self, span: trace.Span, duration_seconds: float) -> None:
        """Record session creation metrics.

        Args:
            span: Current span
            duration_seconds: Creation duration in seconds
        """
        span.set_attribute("meta_data.session_creation_duration_seconds", duration_seconds)

        if self.session_creation_latency_histogram:
            self.session_creation_latency_histogram.record(duration_seconds)


