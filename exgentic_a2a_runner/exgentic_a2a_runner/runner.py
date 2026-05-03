"""Main runner for Exgentic A2A Runner.

Orchestrates session creation, A2A calls, evaluation, and telemetry collection.
"""

import argparse
import logging
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Optional

from .a2a_client import A2AProxyClient
from .config import Config
from .exgentic_adapter import ExgenticAdapter, SessionData
from .otel import OTELInstrumentation
from .prompt import build_prompt

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Suppress verbose logs from third-party libraries
logging.getLogger("httpcore").setLevel(logging.WARNING)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("urllib3").setLevel(logging.WARNING)
logging.getLogger("mcp.client.streamable_http").setLevel(logging.WARNING)
logging.getLogger("asyncio").setLevel(logging.WARNING)


class SessionResult:
    """Result of a single session execution."""

    def __init__(
        self,
        session_id: str,
        success: bool,
        latency_seconds: float,
        evaluation_result: bool,
        creation_time_seconds: float = 0.0,
        agent_processing_seconds: float = 0.0,
        evaluation_time_seconds: float = 0.0,
        error: Optional[str] = None,
        response_chars: Optional[int] = None,
    ):
        self.session_id = session_id
        self.success = success
        self.latency_seconds = latency_seconds
        self.evaluation_result = evaluation_result
        self.creation_time_seconds = creation_time_seconds
        self.agent_processing_seconds = agent_processing_seconds
        self.evaluation_time_seconds = evaluation_time_seconds
        self.error = error
        self.response_chars = response_chars


class RunSummary:
    """Summary of the entire run."""

    def __init__(self):
        self.start_time = time.time()
        self.results: List[SessionResult] = []
        self._lock = threading.Lock()

    def add_result(self, result: SessionResult) -> None:
        """Add a session result (thread-safe)."""
        with self._lock:
            self.results.append(result)

    def get_summary(self) -> dict:
        """Get summary statistics."""
        total_time = time.time() - self.start_time
        attempted = len(self.results)
        succeeded = sum(1 for r in self.results if r.success)
        failed = attempted - succeeded
        
        # Calculate evaluation success rate
        evaluated = sum(1 for r in self.results if r.success)
        eval_succeeded = sum(1 for r in self.results if r.success and r.evaluation_result)
        eval_success_rate = (eval_succeeded / evaluated * 100) if evaluated > 0 else 0

        latencies = [r.latency_seconds for r in self.results]
        avg_latency = sum(latencies) / len(latencies) if latencies else 0

        # Calculate percentiles
        sorted_latencies = sorted(latencies)
        p50 = sorted_latencies[len(sorted_latencies) // 2] if sorted_latencies else 0
        p95_idx = min(int(len(sorted_latencies) * 0.95), len(sorted_latencies) - 1)
        p95 = sorted_latencies[p95_idx] if sorted_latencies else 0

        # Calculate separate timing metrics for all sessions
        creation_times = [r.creation_time_seconds for r in self.results]
        agent_times = [r.agent_processing_seconds for r in self.results]
        eval_times = [r.evaluation_time_seconds for r in self.results]
        
        avg_creation = sum(creation_times) / len(creation_times) if creation_times else 0
        avg_agent = sum(agent_times) / len(agent_times) if agent_times else 0
        avg_eval = sum(eval_times) / len(eval_times) if eval_times else 0

        return {
            "sessions_attempted": attempted,
            "sessions_succeeded": succeeded,
            "sessions_with_error": failed,
            "evaluation_success_rate": eval_success_rate,
            "total_wall_time_seconds": total_time,
            "average_latency_seconds": avg_latency,
            "p50_latency_seconds": p50,
            "p95_latency_seconds": p95,
            "average_creation_time_seconds": avg_creation,
            "average_agent_processing_seconds": avg_agent,
            "average_evaluation_time_seconds": avg_eval,
        }

    def print_summary(self, max_parallel_sessions: int = 1) -> None:
        """Print summary to console.
        
        Args:
            max_parallel_sessions: Maximum number of parallel sessions configured
        """
        summary = self.get_summary()

        print("\n" + "=" * 60)
        print("RUN SUMMARY")
        print("=" * 60)
        print(f"Max Parallel Sessions: {max_parallel_sessions}")
        print(f"Sessions Attempted:   {summary['sessions_attempted']}")
        print(f"Sessions Succeeded:   {summary['sessions_succeeded']}")
        print(f"Sessions With Error:  {summary['sessions_with_error']}")
        print(f"Evaluation Success:   {summary['evaluation_success_rate']:.1f}%")
        print(f"Total Wall Time:      {summary['total_wall_time_seconds']:.2f}s")
        print()
        print("TIMING BREAKDOWN (average per session)")
        print(f"  Session Creation:   {summary['average_creation_time_seconds']:.2f}s")
        print(f"  Agent Processing:   {summary['average_agent_processing_seconds']:.2f}s")
        print(f"  Evaluation:         {summary['average_evaluation_time_seconds']:.2f}s")
        print()
        print("AGENT PROCESSING LATENCY")
        print(f"  Average:            {summary['average_latency_seconds']:.2f}s")
        print(f"  P50:                {summary['p50_latency_seconds']:.2f}s")
        print(f"  P95:                {summary['p95_latency_seconds']:.2f}s")
        print("=" * 60)
        
        # Print error table if there are any failures
        failed_results = [r for r in self.results if not r.success and r.error]
        if failed_results:
            print("\nFAILED SESSIONS")
            print("=" * 60)
            print(f"{'Session ID':<40} {'Error':<20}")
            print("-" * 60)
            for result in failed_results:
                # Truncate error message if too long
                error = result.error or "Unknown error"
                error_msg = error[:100] + "..." if len(error) > 100 else error
                print(f"{result.session_id:<40} {error_msg:<20}")
            print("=" * 60)
        
        print()


class Runner:
    """Main runner orchestrating session execution."""

    def __init__(self, config: Config):
        """Initialize runner.

        Args:
            config: Complete configuration
        """
        self.config = config
        self.exgentic = ExgenticAdapter(config.exgentic)
        self.a2a_client = A2AProxyClient(
            config.a2a,
            otel_enabled=bool(config.otel.exporter_endpoint),
        )
        self.otel = OTELInstrumentation(config.otel)
        self.summary = RunSummary()
        self.max_parallel_sessions = config.exgentic.max_parallel_sessions
        self.prometheus = None

    def initialize(self) -> None:
        """Initialize all components."""
        logger.info("Initializing runner components")
        self.otel.initialize()
        self.exgentic.initialize()

        # Initialize Prometheus metrics collector (optional)
        if self.config.prometheus.enabled:
            from .prometheus_client import PrometheusMetricsCollector

            collector = PrometheusMetricsCollector(
                prometheus_url=self.config.prometheus.url,
                namespace=self.config.prometheus.namespace,
                mcp_pod_prefix=self.config.prometheus.mcp_pod_prefix,
                a2a_pod_prefix=self.config.prometheus.a2a_pod_prefix,
            )
            if collector.check_connectivity():
                self.prometheus = collector
                logger.info("Prometheus metrics collection enabled (%s)", self.config.prometheus.url)
            else:
                logger.warning("Prometheus not reachable at %s, infra metrics disabled", self.config.prometheus.url)

        logger.info("Runner initialization complete")

    def process_task(self, task_id: str) -> SessionResult:
        """Process a single task by creating a session on-demand.

        Follows the execution model:
        1. Create session (on-demand by worker)
        2. Build prompt with session_id
        3. Send to agent via A2A
        4. Evaluate session
        5. Close session
        6. Record statistics with separate timings

        Args:
            task_id: Task ID to process

        Returns:
            SessionResult with execution details and separate timings
        """
        start_time = time.time()
        session_id: str = f"pending-{task_id}"  # Initialize with temporary ID
        creation_time: float = 0.0  # Initialize creation time

        logger.info(f"Processing task: {task_id}")

        # Start OTEL span (session creation will be inside)
        with self.otel.session_span(
            session_id=f"pending-{task_id}",  # Temporary ID until session is created
            mcp_server_url=self.config.exgentic.mcp_server_url,
            a2a_base_url=self.config.a2a.base_url,
            a2a_timeout=self.config.a2a.timeout_seconds,
            benchmark_name=self.config.exgentic.benchmark_name,
            agent_name=self.config.exgentic.agent_name,
            task_id=task_id,
            num_parallel_tasks=self.config.exgentic.max_parallel_sessions,
        ) as span:
            try:
                # Create session on-demand (inside the CHAIN span)
                creation_start = time.time()
                with self.otel.child_span("MCP.CreateSession") as create_span:
                    try:
                        session_data = self.exgentic.create_session(task_id=task_id)
                        session_id = session_data.session_id
                        creation_time = time.time() - creation_start
                        # Update the session_id attribute on the parent span
                        span.set_attribute("metadata.session_id", session_id)
                        create_span.set_attribute("metadata.session_id", session_id)
                        logger.info(f"Created session {session_id} for task {task_id} in {creation_time:.2f}s")
                    except Exception as e:
                        creation_time = time.time() - creation_start
                        error_msg = f"Failed to create session: {type(e).__name__}: {str(e)}"
                        logger.error(error_msg)
                        create_span.set_attribute("error", True)
                        create_span.set_attribute("error.message", error_msg)
                        # Record failure and return early
                        self.otel.record_failure(span, e, "session_creation_failed")
                        return SessionResult(
                            session_id=f"failed-{task_id}",
                            success=False,
                            latency_seconds=0.0,
                            evaluation_result=False,
                            creation_time_seconds=creation_time,
                            agent_processing_seconds=0.0,
                            evaluation_time_seconds=0.0,
                            error=error_msg,
                        )

                # Build prompt with session_id and context
                with self.otel.child_span("Prompt.Build") as prompt_span:
                    prompt = build_prompt(session_data.task, session_data.session_id, session_data.context)
                    # Record prompt on the build span
                    self.otel.record_prompt(prompt_span, prompt)
                
                # Also record on parent span for backward compatibility
                self.otel.record_prompt(span, prompt)

                if self.config.debug.log_prompt:
                    logger.debug(f"Prompt length: {len(prompt)} chars")

                # Send A2A request (agent processing time)
                agent_start = time.time()
                with self.otel.child_span("Agent.Call") as a2a_span:
                    # Set OpenInference span kind for agent call
                    a2a_span.set_attribute("openinference.span.kind", "AGENT")
                    response = self.a2a_client.send_prompt(prompt, session_id=session_id)
                    agent_processing_time = time.time() - agent_start
                    # Record prompt and response on the send span
                    self.otel.record_prompt(a2a_span, prompt)
                    self.otel.record_response(a2a_span, response)
                    self.otel.record_a2a_request(a2a_span, agent_processing_time)

                # Also record on parent span for backward compatibility
                self.otel.record_a2a_request(span, agent_processing_time)
                self.otel.record_response(span, response)

                if self.config.debug.log_response:
                    logger.debug(f"Response length: {len(response)} chars")

                # Evaluate session
                eval_start = time.time()
                with self.otel.child_span("Evaluator.Evaluate") as eval_span:
                    # Set OpenInference span kind for evaluator
                    eval_span.set_attribute("openinference.span.kind", "EVALUATOR")
                    evaluation_result = self.exgentic.evaluate_session(session_id)
                    evaluation_time = time.time() - eval_start
                    # Record evaluation result using Phoenix evaluation conventions
                    eval_span.set_attribute("eval.name", "exgentic_benchmark_evaluation")
                    eval_span.set_attribute("eval.result", "pass" if evaluation_result else "fail")
                    eval_span.set_attribute("eval.score", 1.0 if evaluation_result else 0.0)
                    eval_span.set_attribute("metadata.evaluation_duration_seconds", evaluation_time)
                    if self.otel.evaluation_latency_histogram:
                        self.otel.evaluation_latency_histogram.record(evaluation_time)
                
                # Also record on parent span for backward compatibility
                self.otel.record_evaluation(span, evaluation_time)

                # Collect infrastructure metrics from Prometheus
                if self.prometheus:
                    try:
                        with self.otel.child_span("Infra.Metrics"):
                            infra_metrics = self.prometheus.collect_session_metrics(
                                creation_start, time.time()
                            )
                            for pod_key, pod_metrics in infra_metrics.items():
                                span.set_attribute(f"infra.{pod_key}.cpu_utilization_pct", pod_metrics.cpu_utilization_pct)
                                span.set_attribute(f"infra.{pod_key}.cpu_limit_cores", pod_metrics.cpu_limit_cores)
                                span.set_attribute(f"infra.{pod_key}.throttle_pct", pod_metrics.throttle_pct)
                                span.set_attribute(f"infra.{pod_key}.memory_max_mb", pod_metrics.memory_max_mb)
                                span.set_attribute(f"infra.{pod_key}.memory_limit_mb", pod_metrics.memory_limit_mb)
                                span.set_attribute(f"infra.{pod_key}.memory_utilization_pct", pod_metrics.memory_utilization_pct)
                                span.set_attribute(f"infra.{pod_key}.network_rx_mb", pod_metrics.network_rx_mb)
                                span.set_attribute(f"infra.{pod_key}.network_tx_mb", pod_metrics.network_tx_mb)
                    except Exception as e:
                        logger.warning("Failed to collect infra metrics: %s", e)

                # Delete session
                with self.otel.child_span("MCP.DeleteSession"):
                    self.exgentic.delete_session(session_id)

                # Record success
                self.otel.record_success(span, evaluation_result)

                total_time = time.time() - start_time
                logger.info(
                    f"Session {session_id} completed in {total_time:.2f}s "
                    f"(creation: {creation_time:.2f}s, agent: {agent_processing_time:.2f}s, eval: {evaluation_time:.2f}s) "
                    f"(evaluation: {'success' if evaluation_result else 'failed'})"
                )

                return SessionResult(
                    session_id=session_id,
                    success=True,
                    latency_seconds=agent_processing_time,  # Latency is now only agent processing time
                    evaluation_result=evaluation_result,
                    creation_time_seconds=creation_time,
                    agent_processing_seconds=agent_processing_time,
                    evaluation_time_seconds=evaluation_time,
                    response_chars=len(response),
                )

            except Exception as e:
                # Classify error type
                error_type = type(e).__name__
                error_msg = str(e)

                logger.error(f"Session {session_id} failed: {error_type}: {error_msg}")

                # Try to delete session even on failure (only if session was created)
                if session_id and not session_id.startswith("pending-"):
                    try:
                        with self.otel.child_span("MCP.DeleteSession"):
                            self.exgentic.delete_session(session_id)
                    except Exception as delete_error:
                        logger.warning(f"Failed to delete session {session_id}: {delete_error}")

                # Record failure
                self.otel.record_failure(span, e, error_type)

                return SessionResult(
                    session_id=session_id,
                    success=False,
                    latency_seconds=0.0,  # No agent processing time on failure
                    evaluation_result=False,
                    creation_time_seconds=creation_time,
                    agent_processing_seconds=0.0,
                    evaluation_time_seconds=0.0,
                    error=f"{error_type}: {error_msg}",
                )

    def run(self) -> int:
        """Run the session processing loop.

        Returns:
            Exit code (0 for success, 1 for failure)
        """
        try:
            self.initialize()

            # Get list of all available task IDs
            logger.info("Fetching available task IDs from Exgentic MCP server")
            task_ids = self.exgentic.get_task_ids()
            logger.info(f"Found {len(task_ids)} tasks to process")

            max_workers = self.config.exgentic.max_parallel_sessions
            
            # Limit task_ids if max_tasks is set
            max_tasks = self.config.exgentic.max_tasks
            if max_tasks is not None:
                task_ids = task_ids[:max_tasks]
                logger.info(f"Processing {len(task_ids)} tasks (limited by max_tasks={max_tasks})")
            else:
                logger.info(f"Processing all {len(task_ids)} tasks")
            
            # Always use ThreadPoolExecutor (works for both sequential and parallel)
            logger.info(f"Processing tasks with {max_workers} worker(s)")
            logger.info("Sessions will be created on-demand by workers")
            
            # Process tasks using ThreadPoolExecutor - sessions created on-demand
            with ThreadPoolExecutor(max_workers=max_workers) as executor:
                # Submit all tasks (not pre-created sessions)
                future_to_task = {
                    executor.submit(self.process_task, task_id): task_id
                    for task_id in task_ids
                }
                
                # Process results as they complete
                for future in as_completed(future_to_task):
                    task_id = future_to_task[future]
                    try:
                        result = future.result()
                        self.summary.add_result(result)
                        
                        self.summary.print_summary(max_parallel_sessions=self.max_parallel_sessions)
                        
                        # Check abort on failure
                        if not result.success and self.config.exgentic.abort_on_failure:
                            logger.error("Aborting due to task failure (ABORT_ON_FAILURE=true)")
                            # Cancel remaining futures
                            for f in future_to_task:
                                f.cancel()
                            break
                    except Exception as e:
                        logger.error(f"Task {task_id} raised exception: {e}")
                        # Create a failure result
                        result = SessionResult(
                            session_id=f"failed-{task_id}",
                            success=False,
                            latency_seconds=0,
                            evaluation_result=False,
                            creation_time_seconds=0.0,
                            agent_processing_seconds=0.0,
                            evaluation_time_seconds=0.0,
                            error=str(e),
                        )
                        self.summary.add_result(result)

            # Print summary
            self.summary.print_summary(max_parallel_sessions=self.max_parallel_sessions)

            # Return success if at least one session succeeded
            if any(r.success for r in self.summary.results):
                return 0
            else:
                return 1

        except Exception as e:
            logger.exception(f"Fatal error in runner: {e}")
            return 1
        finally:
            # Shutdown components
            try:
                self.exgentic.shutdown()
            except Exception as e:
                logger.warning(f"Error shutting down Exgentic adapter: {e}")
            
            self.otel.shutdown()


def parse_args() -> argparse.Namespace:
    """Parse command line arguments.

    Returns:
        Parsed arguments
    """
    parser = argparse.ArgumentParser(
        description="Exgentic A2A Runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Environment Variables:
  EXGENTIC_MCP_SERVER_URL   MCP server endpoint (required)
  EXGENTIC_MCP_TIMEOUT_SECONDS  MCP timeout in seconds (default: 60)
  MAX_TASKS                 Maximum number of sessions to process
  ABORT_ON_FAILURE          Stop on first failure (default: false)

  A2A_BASE_URL              A2A endpoint base URL (required)
  A2A_TIMEOUT_SECONDS       Request timeout in seconds (default: 300)
  A2A_AUTH_TOKEN            Bearer token for authentication
  A2A_VERIFY_TLS            Verify TLS certificates (default: true)
  A2A_ENDPOINT_PATH         Endpoint path (default: /v1/chat)

  OTEL_SERVICE_NAME         Service name for telemetry (default: exgentic-a2a-runner)
  OTEL_EXPORTER_OTLP_ENDPOINT  OTLP exporter endpoint
  OTEL_EXPORTER_OTLP_PROTOCOL  OTLP protocol (default: grpc)
  OTEL_RESOURCE_ATTRIBUTES  Additional resource attributes
  OTEL_EXPORTER_OTLP_INSECURE  Use insecure connection for OTLP (default: true)

  LOG_LEVEL                 Log level: DEBUG, INFO, WARNING, ERROR (default: INFO)
  LOG_PROMPT                Log prompt details (default: 0)
  LOG_RESPONSE              Log response details (default: 0)
        """,
    )

    parser.add_argument(
        "--log-level",
        "-l",
        type=str,
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        default=None,
        help="Set log level (DEBUG, INFO, WARNING, ERROR). Overrides LOG_LEVEL environment variable.",
    )

    return parser.parse_args()


def main() -> int:
    """Main entry point.

    Returns:
        Exit code
    """
    args = parse_args()

    # Determine log level from args or environment
    import os
    if args.log_level:
        log_level_str = args.log_level
    else:
        # Check environment variable
        log_level_str = os.getenv("LOG_LEVEL", "INFO").upper()
    
    # Set log level
    log_level = getattr(logging, log_level_str, logging.INFO)
    logging.getLogger().setLevel(log_level)
    logger.info(f"Log level set to: {log_level_str}")

    try:
        # Load configuration from environment
        config = Config.from_env()
        logger.info(f"Configuration loaded: {config}")

        # Create and run
        runner = Runner(config)
        return runner.run()

    except ValueError as e:
        logger.error(f"Configuration error: {e}")
        return 1
    except KeyboardInterrupt:
        logger.info("Interrupted by user")
        return 130
    except Exception as e:
        logger.exception(f"Unexpected error: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())


