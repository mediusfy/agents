from pyflakes.api import checkPath
from pyflakes.reporter import Reporter
import io

def lint_python_file(file_path: str) -> str:
    """
    Lints a Python file using pyflakes and returns the errors.
    Returns 'No issues found.' if the file is clean.
    """
    string_io = io.StringIO()
    reporter = Reporter(string_io, string_io)
    if checkPath(file_path, reporter) > 0:
        return string_io.getvalue()
    return "No issues found."
