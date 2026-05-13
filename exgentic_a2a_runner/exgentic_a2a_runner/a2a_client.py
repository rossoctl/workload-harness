"""A2A client using the standard a2a-sdk.

Uses the official A2A SDK (ClientFactory, streaming send_message) to communicate
with A2A agent endpoints, matching the reference implementation in test_a2a_agent.py.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from typing import Any, Dict, Optional

from .config import A2AConfig

logger = logging.getLogger(__name__)


class A2AProxyClient:
    """Client for A2A protocol communication using the standard a2a-sdk."""

    def __init__(self, config: A2AConfig, otel_enabled: bool = False):
        self.config = config
        self.otel_enabled = otel_enabled
        self._local = threading.local()

        logger.info(f"A2A client initialized for {config.base_url}")

    def _get_event_loop(self) -> asyncio.AbstractEventLoop:
        """Get or create thread-local event loop."""
        if not hasattr(self._local, "loop"):
            self._local.loop = asyncio.new_event_loop()
        return self._local.loop

    def _run_async(self, coro):
        """Run async coroutine in thread-local event loop."""
        loop = self._get_event_loop()
        return loop.run_until_complete(coro)

    def send_prompt(
        self,
        prompt: str,
        poll_interval_s: float = 0.5,
        timeout_s: Optional[float] = None,
    ) -> str:
        """Send prompt to A2A endpoint and get response.

        Args:
            prompt: The prompt text to send
            poll_interval_s: Unused (kept for API compatibility)
            timeout_s: Timeout for task completion (default: config timeout)

        Returns:
            Plain text response from the agent
        """
        if timeout_s is None:
            timeout_s = float(self.config.timeout_seconds)

        # Capture the current OTEL context from the calling thread so we can
        # propagate it into the async event loop (which has its own context).
        otel_context = None
        if self.otel_enabled:
            try:
                from opentelemetry import context as otel_ctx

                otel_context = otel_ctx.get_current()
            except ImportError:
                pass

        return self._run_async(self._async_send_prompt(prompt, timeout_s, otel_context))

    async def _async_send_prompt(self, prompt: str, timeout_s: float, otel_context=None) -> str:
        """Async implementation using the standard a2a-sdk."""
        import uuid

        import httpx
        from a2a.client import ClientConfig, ClientFactory, create_text_message_object
        from a2a.client.card_resolver import A2ACardResolver
        from a2a.types import Role, TextPart

        # Restore the OTEL context from the calling thread so that
        # httpx instrumentation creates spans under the correct parent.
        if otel_context is not None:
            try:
                from opentelemetry import context as otel_ctx

                token = otel_ctx.attach(otel_context)
            except ImportError:
                token = None
        else:
            token = None

        # x-session-id lets the IBAC sidecar (if present) key intent per prompt.
        # Harmless when IBAC isn't deployed; the agent ignores unknown headers.
        session_id = uuid.uuid4().hex
        httpx_client = httpx.AsyncClient(
            timeout=timeout_s,
            headers={"x-session-id": session_id},
        )
        if self.otel_enabled:
            try:
                from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
            except ImportError as exc:
                raise RuntimeError(
                    "OTEL is enabled but opentelemetry-instrumentation-httpx is not installed. "
                    "Install it with: pip install opentelemetry-instrumentation-httpx"
                ) from exc

            HTTPXClientInstrumentor().instrument_client(httpx_client)

            if otel_context is None:
                raise RuntimeError(
                    "OTEL is enabled but no trace context was captured from the calling thread. "
                    "Ensure an active OTEL span exists when send_prompt() is called."
                )

        try:
            client_config = ClientConfig(httpx_client=httpx_client)

            # Fetch the agent card and override the URL for port-forwarding
            resolver = A2ACardResolver(
                httpx_client=httpx_client,
                base_url=self.config.base_url,
            )
            card = await resolver.get_agent_card()

            logger.debug(f"Agent card original URL: '{card.url}'")
            card.url = self.config.base_url
            logger.debug(f"Overridden URL to: '{self.config.base_url}'")

            client = ClientFactory(client_config).create(card=card)

            message = create_text_message_object(role=Role.user, content=prompt)

            result_text = ""
            task_id = None
            event_count = 0

            async for response in client.send_message(message):
                event_count += 1

                if isinstance(response, tuple):
                    task, event = response
                    if task_id is None:
                        task_id = task.id
                        logger.debug(f"Task ID: {task_id}")

                    # Extract text from artifact events
                    if event and hasattr(event, "artifact") and event.artifact:
                        for part in event.artifact.parts:
                            if hasattr(part, "root") and isinstance(part.root, TextPart):
                                result_text += part.root.text
                else:
                    # Direct message response
                    if hasattr(response, "parts"):
                        for part in response.parts:
                            if hasattr(part, "root") and isinstance(part.root, TextPart):
                                result_text += part.root.text

            logger.debug(
                f"Completed: {event_count} events, {len(result_text)} chars"
            )
            return result_text

        finally:
            await httpx_client.aclose()
            # Detach the OTEL context
            if token is not None:
                try:
                    from opentelemetry import context as otel_ctx

                    otel_ctx.detach(token)
                except Exception:
                    pass
