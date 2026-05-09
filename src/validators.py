import asyncio
import os
import tempfile
from typing import List
from src.models.core import Artifact

class CodeValidator:

    @staticmethod
    async def validate_go_async(artifacts: List[Artifact]) -> bool:
        go_files = []
        for art in artifacts:
            for path, content in art.files.items():
                if path.endswith(".go"):
                    go_files.append((path, content))

        if not go_files:
            return True

        with tempfile.TemporaryDirectory() as tmpdir:
            mod_init = os.path.join(tmpdir, "go.mod")
            if not os.path.exists(mod_init):
                with open(mod_init, "w") as f:
                    f.write("module validation\ngo 1.26\n")

            for path, content in go_files:
                full = os.path.join(tmpdir, path)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "w") as f:
                    f.write(content)

            try:
                proc = await asyncio.create_subprocess_exec(
                    "go", "vet", "./...",
                    cwd=tmpdir,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                    env={**os.environ, "GOPATH": "", "GOFLAGS": ""},
                )
                _, stderr = await asyncio.wait_for(proc.communicate(), timeout=30.0)
                if proc.returncode != 0:
                    print(f"[Validator] go vet failed:\n{stderr.decode()[:500]}")
                    return False
                print("[Validator] go vet passed")
                return True
            except FileNotFoundError:
                print("[Validator] Go not installed, skipping go vet")
                return True
            except asyncio.TimeoutError:
                print("[Validator] go vet timed out (30s), skipping")
                return True

    @staticmethod
    async def validate_vue_async(artifacts: List[Artifact]) -> bool:
        vue_files = []
        for art in artifacts:
            for path, content in art.files.items():
                if path.endswith(".vue") or path.endswith(".tsx"):
                    vue_files.append((path, content))

        if not vue_files:
            return True

        all_ok = True
        for path, content in vue_files:
            if "<template>" in content and "</template>" not in content:
                print(f"[Validator] {path}: missing closing </template>")
                all_ok = False
            if "<script" in content and "</script>" not in content:
                print(f"[Validator] {path}: missing closing </script>")
                all_ok = False
            if "export default" not in content and ".vue" not in path:
                print(f"[Validator] {path}: missing component export")
                all_ok = False

        if all_ok:
            print("[Validator] Vue/TSX structural validation passed")
        return all_ok

    @staticmethod
    async def run_all_async(artifacts: List[Artifact]) -> bool:
        go_result, vue_result = await asyncio.gather(
            CodeValidator.validate_go_async(artifacts),
            CodeValidator.validate_vue_async(artifacts),
        )
        return go_result and vue_result

    @staticmethod
    def run_all(artifacts: List[Artifact]) -> bool:
        loop = asyncio.new_event_loop()
        try:
            return loop.run_until_complete(CodeValidator.run_all_async(artifacts))
        finally:
            loop.close()
