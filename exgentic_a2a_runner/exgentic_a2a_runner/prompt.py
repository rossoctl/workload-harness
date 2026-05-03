"""Prompt construction for Exgentic A2A Runner.

Builds prompts with session_id for agent to use with benchmark tools.
"""

from typing import Any, Dict, Optional


def build_prompt(task: str, session_id: str, context: Optional[Dict[str, Any]] = None) -> str:
    """Build prompt with task, session_id, and context.

    The prompt format includes the task description, context information, and explicitly instructs
    the agent to use the provided session_id in all interactions with the
    benchmark tools.

    Args:
        task: Task description from Exgentic MCP server
        session_id: Session identifier to use for tool calls
        context: Optional context dictionary with additional information

    Returns:
        Formatted prompt string
    """
    prompt_parts = [f"""The task you are to complete is:
{task}"""]
    
    # Add context if provided
    if context:
        prompt_parts.append("\nContext:")
        for key, value in context.items():
            prompt_parts.append(f"- {key}: {value}")
    
    prompt_parts.append(f"""
IMPORTANT:  If you are asked to submit an answer, make sure you call the submit MCP tool.""")

    return "\n".join(prompt_parts)


