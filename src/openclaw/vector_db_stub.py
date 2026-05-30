"""Lightweight stub for vector_db when heavy ML deps (sentence-transformers, asyncpg) aren't installed."""


class _StubVectorDB:
    def search(self, collection: str, query: str) -> list[str]:  # noqa: ARG002
        return ["Vector DB not available — install heavy dependencies (sentence-transformers, asyncpg, pgvector)"]

    def add_documents(self, collection: str, docs: list[str], metadatas: list[dict], ids: list[str]) -> None:  # noqa: ARG002
        pass


vector_db = _StubVectorDB()
