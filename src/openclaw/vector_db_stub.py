"""Lightweight stub for vector_db when heavy ML deps aren't installed."""


class _StubVectorDB:
    def search(self, collection: str, query: str) -> list[str]:
        return ["Vector DB not available — install heavy dependencies (chromadb, sentence-transformers)"]

    def add_documents(self, collection: str, docs: list[str], metadatas: list[dict], ids: list[str]) -> None:
        pass


vector_db = _StubVectorDB()
