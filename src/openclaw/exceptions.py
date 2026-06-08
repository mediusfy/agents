"""Typed exception hierarchy for the OpenClaw ecosystem."""


class OpenClawError(Exception):
    """Base exception for all OpenClaw errors."""


class ConfigurationError(OpenClawError):
    """Invalid or missing configuration."""


class AgentNotFoundError(OpenClawError):
    """Requested agent is not registered in the registry."""


class AgentExecutionError(OpenClawError):
    """An agent's LLM call or tool execution failed."""

    def __init__(self, message, is_retryable=True):
        super().__init__(message)
        self.is_retryable = is_retryable


class PipelineError(OpenClawError):
    """Pipeline-level failure that should abort the current run."""


class PipelineStepFailedError(PipelineError):
    """A specific pipeline step failed and cannot be retried."""


class ValidationError(OpenClawError):
    """Code or data validation failed."""


class CheckpointError(OpenClawError):
    """Checkpoint save/load/clear operation failed."""


class PathTraversalError(OpenClawError):
    """Detected an attempt to write outside the allowed directory."""


class OpenclawDependencyError(ImportError):
    """Raised when an optional dependency required by a runtime path is missing."""
