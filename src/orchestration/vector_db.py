"""Vector similarity search via PostgreSQL + pgvector.

All methods are async. Sync callers must await them. There are no sync wrappers.

Collection names map to pgvector tables, each containing:
  - id        TEXT PRIMARY KEY
  - metadata  JSONB NOT NULL DEFAULT '{}'::jsonb
  - embedding vector(384)  — all-MiniLM-L6-v2 produces 384-dim vectors
  - content   TEXT NOT NULL

Heavy dependencies (sentence-transformers, numpy) are imported lazily —
importing this module never fails.
"""

import json
import logging
import os
from typing import Any

from orchestration.exceptions import OrgitrationDependencyError
from orchestration.settings import settings

logger = logging.getLogger(__name__)

_embeddings: Any = None
_connection_pools: dict[str, Any] = {}
_initialized_tables: set[str] = set()
_test_pool_override: Any = None


def _set_test_pool(pool: Any):
    global _test_pool_override
    _test_pool_override = pool


def _require_vector_deps():
    try:
        import numpy as _  # noqa: F401
    except ImportError as exc:
        raise OrgitrationDependencyError(
            "vector_db requires numpy. Install with: pip install orchestration[vector]"
        ) from exc


def _get_embeddings():
    global _embeddings
    if _embeddings is None:
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError as exc:
            raise OrgitrationDependencyError(
                "vector_db requires sentence-transformers. Install with: pip install orchestration[vector]"
            ) from exc
        _embeddings = SentenceTransformer("all-MiniLM-L6-v2")
    return _embeddings


def _dsn() -> str:
    return settings.database_url or os.environ.get("DATABASE_URL", "postgresql://localhost:5432/orchestration")


async def _get_pool():
    if _test_pool_override is not None:
        return _test_pool_override
    import asyncpg

    dsn = _dsn()
    if dsn not in _connection_pools:
        _connection_pools[dsn] = await asyncpg.create_pool(dsn, min_size=1, max_size=5)
    return _connection_pools[dsn]


async def _ensure_table(collection_name: str):
    if collection_name in _initialized_tables:
        return
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        await conn.execute(f"""
            CREATE TABLE IF NOT EXISTS v_{collection_name} (
                id        TEXT PRIMARY KEY,
                metadata  JSONB NOT NULL DEFAULT '{{}}'::jsonb,
                embedding vector(384) NOT NULL,
                content   TEXT NOT NULL
            )
        """)
        await conn.execute(f"""
            CREATE INDEX IF NOT EXISTS idx_{collection_name}_embedding
            ON v_{collection_name}
            USING ivfflat (embedding vector_cosine_ops)
            WITH (lists = 100)
        """)
    _initialized_tables.add(collection_name)


def _to_embedding(text: str) -> list[float]:
    import numpy as np

    model = _get_embeddings()
    vec = model.encode(text, normalize_embeddings=True)
    if isinstance(vec, np.ndarray):
        return vec.tolist()
    return list(vec)


class VectorDBManager:
    async def add_documents(
        self,
        collection_name: str,
        documents: list[str],
        metadatas: list[dict],
        ids: list[str],
    ):
        try:
            _require_vector_deps()
            await _ensure_table(collection_name)
            pool = await _get_pool()
            async with pool.acquire() as conn:
                for doc_text, meta, doc_id in zip(documents, metadatas, ids, strict=True):
                    embedding = _to_embedding(doc_text)
                    embedding_str = "[" + ",".join(str(x) for x in embedding) + "]"
                    await conn.execute(
                        f"""
                        INSERT INTO v_{collection_name} (id, metadata, embedding, content)
                        VALUES ($1, $2::jsonb, $3::vector, $4)
                        ON CONFLICT (id) DO UPDATE SET
                            metadata = EXCLUDED.metadata,
                            embedding = EXCLUDED.embedding,
                            content   = EXCLUDED.content
                        """,
                        doc_id,
                        _serialize_meta(meta),
                        embedding_str,
                        doc_text,
                    )
        except OrgitrationDependencyError as exc:
            logger.warning("Vector DB add_documents called but vector dependencies are not installed: %s", exc)

    async def search(
        self,
        collection_name: str,
        query: str,
        n_results: int = 3,
    ) -> list[str]:
        try:
            _require_vector_deps()
            await _ensure_table(collection_name)
            embedding = _to_embedding(query)
            embedding_str = "[" + ",".join(str(x) for x in embedding) + "]"
            pool = await _get_pool()
            async with pool.acquire() as conn:
                rows = await conn.fetch(
                    f"""
                    SELECT content
                    FROM v_{collection_name}
                    ORDER BY embedding <=> $1::vector
                    LIMIT $2
                    """,
                    embedding_str,
                    n_results,
                )
                return [row["content"] for row in rows]
        except OrgitrationDependencyError as exc:
            logger.warning("Vector DB search called but vector dependencies are not installed: %s", exc)
            return ["Vector DB not available — install heavy dependencies (sentence-transformers, asyncpg, pgvector)"]

    async def ingest_url(self, collection_name: str, url: str) -> str:
        try:
            from langchain_community.document_loaders import WebBaseLoader
            from langchain_text_splitters import RecursiveCharacterTextSplitter
        except ImportError as exc:
            raise OrgitrationDependencyError(
                "vector_db.ingest_url requires extra dependencies. Install with: pip install orchestration[ingest]"
            ) from exc
        _require_vector_deps()
        loader = WebBaseLoader(url)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)
        texts = [d.page_content for d in splits]
        metas = [{"source": url} for _ in splits]
        ids = [f"url_{id(s)}" for s in splits]
        await self.add_documents(collection_name, texts, metas, ids)
        return f"Ingested {len(splits)} chunks from {url}"

    async def ingest_pdf(self, collection_name: str, file_path: str) -> str:
        try:
            from langchain_community.document_loaders import PyPDFLoader
            from langchain_text_splitters import RecursiveCharacterTextSplitter
        except ImportError as exc:
            raise OrgitrationDependencyError(
                "vector_db.ingest_pdf requires extra dependencies. Install with: pip install orchestration[ingest]"
            ) from exc
        _require_vector_deps()
        loader = PyPDFLoader(file_path)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)
        texts = [d.page_content for d in splits]
        metas = [{"source": file_path} for _ in splits]
        ids = [f"pdf_{id(s)}" for s in splits]
        await self.add_documents(collection_name, texts, metas, ids)
        return f"Ingested {len(splits)} chunks from PDF."


vector_db = VectorDBManager()


def _serialize_meta(meta: dict[str, Any] | None) -> str:
    if meta is None:
        return "{}"
    cleaned: dict[str, Any] = {}
    for k, v in meta.items():
        if isinstance(v, (str, int, float, bool)):
            cleaned[k] = v
        elif v is None:
            cleaned[k] = None
        else:
            try:
                json.dumps(v)
                cleaned[k] = v
            except (TypeError, ValueError):
                cleaned[k] = str(v)
    return json.dumps(cleaned)
