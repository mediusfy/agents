import os
import chromadb
from chromadb.utils import embedding_functions

class VectorDBManager:
    def __init__(self):
        self.persist_directory = os.getenv("VECTOR_DB_DIR", "./.claw-vectordb")
        os.makedirs(self.persist_directory, exist_ok=True)
        self.client = chromadb.PersistentClient(path=self.persist_directory)
        self.ef = embedding_functions.DefaultEmbeddingFunction()

    def _get_collection(self, name: str):
        return self.client.get_or_create_collection(name=name, embedding_function=self.ef)

    def add_documents(self, collection_name: str, documents: list[str], metadatas: list[dict], ids: list[str]):
        collection = self._get_collection(collection_name)
        collection.upsert(documents=documents, metadatas=metadatas, ids=ids)

    def search(self, collection_name: str, query: str, n_results: int = 3) -> list[str]:
        try:
            collection = self._get_collection(collection_name)
            results = collection.query(query_texts=[query], n_results=n_results)
            if not results["documents"] or not results["documents"][0]:
                return []
            return results["documents"][0]
        except Exception as e:
            print(f"[VectorDB] Search failed: {e}")
            return []

vector_db = VectorDBManager()
