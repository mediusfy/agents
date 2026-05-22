import asyncio
import os
from typing import Any

from langchain_community.document_loaders import PyPDFLoader, WebBaseLoader
from langchain_community.vectorstores import Chroma
from langchain_text_splitters import RecursiveCharacterTextSplitter

from openclaw.settings import settings

_embeddings: Any = None


def _get_embeddings():
    """Lazy-load HuggingFace embeddings to avoid heavy import at module level."""
    global _embeddings
    if _embeddings is None:
        from langchain_huggingface import HuggingFaceEmbeddings

        _embeddings = HuggingFaceEmbeddings(model_name="all-MiniLM-L6-v2")
    return _embeddings


class VectorDBManager:
    def __init__(self):
        self.persist_directory = str(settings.vector_db_dir)
        os.makedirs(self.persist_directory, exist_ok=True)
        self._collections = {}

    def _get_collection(self, collection_name: str) -> Chroma:
        if collection_name not in self._collections:
            self._collections[collection_name] = Chroma(
                collection_name=collection_name,
                embedding_function=_get_embeddings(),
                persist_directory=self.persist_directory,
            )
        return self._collections[collection_name]

    def add_documents(self, collection_name: str, documents: list[str], metadatas: list[dict], ids: list[str]):
        store = self._get_collection(collection_name)
        store.add_texts(texts=documents, metadatas=metadatas, ids=ids)

    def search(self, collection_name: str, query: str, n_results: int = 3) -> list[str]:
        try:
            store = self._get_collection(collection_name)
            docs = store.similarity_search(query, k=n_results)
            return [doc.page_content for doc in docs]
        except Exception as e:
            print(f"[VectorDB] Search failed: {e}")
            return []

    async def async_add_documents(
        self, collection_name: str, documents: list[str], metadatas: list[dict], ids: list[str]
    ):
        await asyncio.to_thread(self.add_documents, collection_name, documents, metadatas, ids)

    async def async_search(self, collection_name: str, query: str, n_results: int = 3) -> list[str]:
        return await asyncio.to_thread(self.search, collection_name, query, n_results)

    def ingest_url(self, collection_name: str, url: str):
        loader = WebBaseLoader(url)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)
        store = self._get_collection(collection_name)
        store.add_documents(splits)
        return f"Ingested {len(splits)} chunks from {url}"

    def ingest_pdf(self, collection_name: str, file_path: str):
        loader = PyPDFLoader(file_path)
        docs = loader.load()
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        splits = text_splitter.split_documents(docs)
        store = self._get_collection(collection_name)
        store.add_documents(splits)
        return f"Ingested {len(splits)} chunks from PDF."

    async def async_ingest_url(self, collection_name: str, url: str) -> str:
        return await asyncio.to_thread(self.ingest_url, collection_name, url)

    async def async_ingest_pdf(self, collection_name: str, file_path: str) -> str:
        return await asyncio.to_thread(self.ingest_pdf, collection_name, file_path)


vector_db = VectorDBManager()
