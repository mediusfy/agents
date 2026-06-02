"""Go build and vet tools for shift-left validation during code generation."""

import os
import tempfile
import asyncio

from openclaw.tools.registry import register_tool

GO_MOD_INIT_TIMEOUT = 10.0
GO_MOD_TIDY_TIMEOUT = 30.0
GO_BUILD_TIMEOUT = 60.0
GO_VET_TIMEOUT = 60.0


async def _run_cmd(*args: str, cwd: str, timeout: float = 30.0) -> None:
    """Run a command with timeout, discarding output."""
    proc = await asyncio.create_subprocess_exec(
        *args,
        cwd=cwd,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        raise


async def _write_files(temp_dir: str, files: dict[str, str]) -> None:
    """Write a dict of file paths to content into temp_dir."""
    for filename, content in files.items():
        filepath = os.path.join(temp_dir, filename)
        os.makedirs(os.path.dirname(filepath), exist_ok=True)
        with open(filepath, "w") as f:
            f.write(content)


async def run_go_build(files: dict[str, str]) -> str:
    """
    Writes the provided Go files to a temporary directory and runs
    'go mod init', 'go mod tidy', and 'go build ./...'.

    Returns 'SUCCESS' if it compiles, or the compiler error output if it fails.

    Args:
        files: A dictionary mapping file paths (e.g., 'main.go') to their string content.
    """
    with tempfile.TemporaryDirectory() as temp_dir:
        await _write_files(temp_dir, files)

        try:
            await _run_cmd("go", "mod", "init", "tempmodule", cwd=temp_dir, timeout=GO_MOD_INIT_TIMEOUT)
        except asyncio.TimeoutError:
            return "BUILD FAILED: 'go mod init' timed out."

        try:
            await _run_cmd("go", "mod", "tidy", cwd=temp_dir, timeout=GO_MOD_TIDY_TIMEOUT)
        except asyncio.TimeoutError:
            return (
                "BUILD FAILED: 'go mod tidy' timed out — the generated code likely "
                "imports a private or non-existent module. Check import paths."
            )

        build_proc = await asyncio.create_subprocess_exec(
            "go", "build", "./...",
            cwd=temp_dir,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            _, stderr = await asyncio.wait_for(build_proc.communicate(), timeout=GO_BUILD_TIMEOUT)
        except asyncio.TimeoutError:
            try:
                build_proc.kill()
            except ProcessLookupError:
                pass
            return "BUILD FAILED: 'go build' timed out (possible circular dependency or slow proxy)."

        if build_proc.returncode == 0:
            return "SUCCESS: Code compiled successfully."
        return f"BUILD FAILED:\n{stderr.decode()}"


async def run_go_vet(files: dict[str, str]) -> str:
    """
    Writes the provided Go files to a temporary directory and runs
    'go mod init', 'go mod tidy', and 'go vet ./...'.

    Returns 'SUCCESS' if it passes, or the vet error output if it fails.

    Args:
        files: A dictionary mapping file paths (e.g., 'main.go') to their string content.
    """
    with tempfile.TemporaryDirectory() as temp_dir:
        await _write_files(temp_dir, files)

        try:
            await _run_cmd("go", "mod", "init", "tempmodule", cwd=temp_dir, timeout=GO_MOD_INIT_TIMEOUT)
        except asyncio.TimeoutError:
            return "VET FAILED: 'go mod init' timed out."

        try:
            await _run_cmd("go", "mod", "tidy", cwd=temp_dir, timeout=GO_MOD_TIDY_TIMEOUT)
        except asyncio.TimeoutError:
            return (
                "VET FAILED: 'go mod tidy' timed out — the generated code likely "
                "imports a private or non-existent module. Check import paths."
            )

        vet_proc = await asyncio.create_subprocess_exec(
            "go", "vet", "./...",
            cwd=temp_dir,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            _, stderr = await asyncio.wait_for(vet_proc.communicate(), timeout=GO_VET_TIMEOUT)
        except asyncio.TimeoutError:
            try:
                vet_proc.kill()
            except ProcessLookupError:
                pass
            return "VET FAILED: 'go vet' timed out."

        if vet_proc.returncode == 0:
            return "SUCCESS: Code passed go vet."
        return f"VET FAILED:\n{stderr.decode()}"


register_tool(
    "run_go_build",
    run_go_build,
    "Compile Go code to check for syntax and import errors. Pass a dict of filename -> content.",
    ["backend", "validation"],
)

register_tool(
    "run_go_vet",
    run_go_vet,
    "Run go vet on Go code to check for suspicious constructs. Pass a dict of filename -> content.",
    ["backend", "validation"],
)
