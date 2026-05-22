from pathlib import Path

from openclaw.models.core import Artifact
from openclaw.utils import safe_path_join


class ArtifactWriter:
    def __init__(self, base_dir: str):
        self.base_dir = Path(base_dir)

    def write(self, artifact: Artifact) -> None:
        for filepath, content in artifact.files.items():
            full_path = safe_path_join(self.base_dir / artifact.agent_name, filepath)
            full_path.parent.mkdir(parents=True, exist_ok=True)
            full_path.write_text(content)
