import datetime
from typing import List, Dict, Any
from pydantic import BaseModel, Field
from openclaw.vector_db import vector_db

class Memory(BaseModel):
    content: str
    timestamp: str = Field(default_factory=lambda: datetime.datetime.now().isoformat())
    metadata: Dict[str, Any] = Field(default_factory=dict)

class VectorMemory:
    def __init__(self, collection_name: str):
        self.collection_name = collection_name

    async def add_memory(self, content: str, metadata: Dict[str, Any] = None):
        """Adds a new memory to the vector store."""
        memory = Memory(content=content, metadata=metadata or {})
        doc_id = f"memory_{memory.timestamp}_{hash(content)}"
        await vector_db.async_add_documents(
            self.collection_name,
            [content],
            [memory.model_dump()],
            [doc_id]
        )

    async def get_relevant_memories(self, query: str, n_results: int = 5) -> List[Memory]:
        """Retrieves the most relevant memories for a given query."""
        results = await vector_db.async_search(self.collection_name, query, n_results=n_results)
        return [Memory(**res) for res in results]

# Global memory instance
long_term_memory = VectorMemory("long_term_memory")
