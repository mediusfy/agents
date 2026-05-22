import logging

from openclaw.models.core import Artifact

logger = logging.getLogger(__name__)


class HumanInTheLoopGate:
    @staticmethod
    def prompt_proceed(artifacts: list[Artifact], auto_yes: bool = False) -> bool:
        if auto_yes:
            return True

        print("\\n=== Artifact Manifest ===")
        for art in artifacts:
            story_id = art.metadata.get("user_story_id", "N/A")
            print(f"- Agent: {art.agent_name} | Story: {story_id}")
            for filepath in art.files:
                print(f"  └── {filepath}")
        print("=========================\\n")

        while True:
            choice = input("Proceed with writing artifacts to disk? [Y/n]: ").strip().lower()
            if choice in ("y", "yes", ""):
                return True
            if choice in ("n", "no"):
                return False
            print("Please enter 'Y' or 'n'.")
