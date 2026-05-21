"""MCP client for communicating with Exgentic MCP server.

Uses streamable HTTP transport to interact with the Exgentic benchmark server.
"""

import asyncio
import json
import logging
import threading
from typing import Any, Dict, Optional, Tuple

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from .config import ExgenticConfig

logger = logging.getLogger(__name__)


class MCPClient:
    """Client for MCP protocol communication with Exgentic server via streamable HTTP.

    This client is thread-safe and maintains a persistent MCP session per thread
    to avoid the overhead of creating a new connection for every operation.
    """

    def __init__(self, config: ExgenticConfig):
        """Initialize MCP client.

        Args:
            config: Exgentic configuration
        """
        self.config = config
        self.mcp_url = config.mcp_server_url
        self._tool_prefix = config.mcp_tool_prefix
        self._local = threading.local()
        self._initialized = False

        logger.info(f"Initialized MCP client for {self.mcp_url}")

    def _tool_name(self, name: str) -> str:
        """Apply the configured tool prefix to a base tool name."""
        if self._tool_prefix:
            return f"{self._tool_prefix}{name}"
        return name
    def _get_event_loop(self) -> asyncio.AbstractEventLoop:
        """Get or create thread-local event loop."""
        if not hasattr(self._local, "loop"):
            self._local.loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self._local.loop)
        return self._local.loop

    def _run_async(self, coro):
        """Run async coroutine in thread-local event loop."""
        loop = self._get_event_loop()
        return loop.run_until_complete(coro)

    async def _ensure_session(self) -> ClientSession:
        """Ensure a persistent MCP session exists for this thread.

        Called from within an async context (inside _run_async), so it
        can safely await without nesting run_until_complete.
        """
        if hasattr(self._local, "mcp_session") and self._local.mcp_session is not None:
            return self._local.mcp_session

        http_ctx = None
        session = None
        try:
            http_ctx = streamable_http_client(self.mcp_url)
            read, write, _ = await http_ctx.__aenter__()

            session = ClientSession(read, write)
            await session.__aenter__()
            await session.initialize()

            self._local.http_ctx = http_ctx
            self._local.mcp_session = session
            return session
        except Exception:
            # Clean up partial resources on failure
            if session is not None:
                try:
                    await session.__aexit__(None, None, None)
                except Exception:
                    pass
            if http_ctx is not None:
                try:
                    await http_ctx.__aexit__(None, None, None)
                except Exception:
                    pass
            raise

    async def _close_session_async(self) -> None:
        """Close the thread-local MCP session if open."""
        session = getattr(self._local, "mcp_session", None)
        http_ctx = getattr(self._local, "http_ctx", None)

        if session is not None:
            try:
                await session.__aexit__(None, None, None)
            except Exception as e:
                logger.warning(f"Error closing MCP session: {e}")
            self._local.mcp_session = None

        if http_ctx is not None:
            try:
                await http_ctx.__aexit__(None, None, None)
            except Exception as e:
                logger.warning(f"Error closing HTTP context: {e}")
            self._local.http_ctx = None

    async def _call_tool(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Call an MCP tool using the persistent session.

        If the session is broken (e.g., server restarted), reconnects once and retries.
        """
        session = await self._ensure_session()
        try:
            result = await session.call_tool(self._tool_name(tool_name), arguments=arguments)
        except (ConnectionError, OSError, TimeoutError) as e:
            # Session may be stale — reconnect and retry once for connection errors only
            logger.debug(f"Connection error calling {tool_name}, reconnecting: {e}")
            await self._close_session_async()
            session = await self._ensure_session()
            result = await session.call_tool(self._tool_name(tool_name), arguments=arguments)
        except BaseExceptionGroup as e:
            # anyio's TaskGroup wraps background task exceptions in BaseExceptionGroup
            # This can occur when the SSE stream fails (e.g., session already cleaned up server-side)
            # For delete_session, this may happen after successful completion
            logger.debug(f"BaseExceptionGroup during {tool_name}: {e}")
            # Re-raise to let caller handle appropriately
            raise

        if not result.content:
            raise RuntimeError(f"Empty response from {tool_name}")

        if result.isError:
            content = result.content[0]
            error_msg = content.text if hasattr(content, "text") else str(content)
            raise RuntimeError(f"MCP tool error: {error_msg}")

        content = result.content[0]
        if hasattr(content, "text"):
            return json.loads(content.text)
        else:
            raise RuntimeError(f"Unexpected content type: {type(content)}")

    def initialize(self) -> None:
        """Initialize MCP client connection.

        Raises:
            RuntimeError: If connection fails
        """
        logger.info(f"Initializing MCP client for {self.mcp_url}")

        try:
            async def _init():
                session = await self._ensure_session()
                tools_result = await session.list_tools()
                return tools_result

            tools_result = self._run_async(_init())
            logger.info(f"Connected to MCP server with {len(tools_result.tools)} tools available")
            self._initialized = True
            logger.info("MCP client initialized successfully")

        except Exception as e:
            logger.error(f"Failed to initialize MCP client: {e}")
            raise RuntimeError(f"MCP client initialization failed: {e}")

    def shutdown(self) -> None:
        """Shutdown MCP client connection and cleanup thread-local resources."""
        if self._initialized:
            try:
                self._run_async(self._close_session_async())
                if hasattr(self._local, "loop"):
                    loop = self._local.loop
                    if not loop.is_closed():
                        loop.close()
                    delattr(self._local, "loop")
                logger.info("MCP client shutdown complete")
            except Exception as e:
                logger.warning(f"Error during MCP client shutdown: {e}")
        self._initialized = False

    def list_tasks(self) -> list[str]:
        """List all available task IDs.

        Returns:
            List of task ID strings

        Raises:
            RuntimeError: If task listing fails
        """
        if not self._initialized:
            raise RuntimeError("MCP client not initialized")

        logger.info("Listing available tasks")

        try:
            data = self._run_async(self._call_tool("list_tasks", {}))
            tasks = data.get("tasks", [])
            logger.info(f"Found {len(tasks)} tasks")
            return tasks

        except Exception as e:
            logger.error(f"Failed to list tasks: {e}")
            raise RuntimeError(f"Task listing failed: {e}")

    def create_session(self, task_id: str) -> Tuple[str, str, Optional[Dict[str, Any]]]:
        """Create a new benchmark session.

        Args:
            task_id: Task ID to create session for.

        Returns:
            Tuple of (session_id, task_description, context)

        Raises:
            RuntimeError: If session creation fails
        """
        if not self._initialized:
            raise RuntimeError("MCP client not initialized")

        logger.info("Creating new benchmark session")

        try:
            assert task_id is not None, "task_id should not be None"
            result = self._run_async(self._call_tool("create_session", {"task_id": task_id}))
            session_id = result["session_id"]
            task = result.get("task", result.get("task_description", ""))
            context = result.get("context")

            logger.info(f"Created session {session_id} for task {task_id}")
            return session_id, task, context

        except Exception as e:
            logger.error(f"Failed to create session: {e}")
            raise RuntimeError(f"Session creation failed: {e}")

    def evaluate_session(self, session_id: str) -> Dict[str, Any]:
        """Evaluate a benchmark session.

        Args:
            session_id: Session ID to evaluate

        Returns:
            Evaluation results

        Raises:
            RuntimeError: If evaluation fails
        """
        if not self._initialized:
            raise RuntimeError("MCP client not initialized")

        logger.info(f"Evaluating session {session_id}")

        try:
            result = self._run_async(self._call_tool("evaluate_session", {"session_id": session_id}))
            logger.info(f"Session {session_id} evaluation complete")
            return result

        except Exception as e:
            logger.error(f"Failed to evaluate session {session_id}: {e}")
            raise RuntimeError(f"Session evaluation failed: {e}")

    def delete_session(self, session_id: str) -> None:
        """Delete a benchmark session.

        Args:
            session_id: Session ID to delete

        Raises:
            RuntimeError: If session deletion fails
        """
        if not self._initialized:
            raise RuntimeError("MCP client not initialized")

        logger.info(f"Deleting session {session_id}")

        try:
            result = self._run_async(self._call_tool("delete_session", {"session_id": session_id}))
            status = result.get("status", "")
            if status != "success":
                error_msg = result.get("error", "")
                if "client has been closed" in error_msg or "No session found" in error_msg:
                    logger.debug(f"Session {session_id} already cleaned up: {error_msg}")
                    return
                raise RuntimeError(f"Session deletion failed: {result}")
            logger.info(f"Session {session_id} deleted")

        except BaseExceptionGroup:  # type: ignore[misc]
            # anyio's TaskGroup wraps background task exceptions in BaseExceptionGroup
            # This occurs when the GET SSE stream fails (e.g., session already cleaned up server-side)
            # The delete_session call has already completed at this point, so we treat it as success
            logger.debug(f"Session {session_id} deleted (SSE stream closed)")
        except Exception as e:
            logger.error(f"Failed to delete session {session_id}: {e}")
            raise RuntimeError(f"Session deletion failed: {e}")
