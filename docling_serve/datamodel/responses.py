"""Deprecated compatibility shim. Use `docling.datamodel.service.responses` instead.

Also defines Onebrief fork-specific response types used by the chunking endpoint
in `app.py`. These were added in the initial fork commit and are not part of
upstream docling.
"""

from typing import List, Tuple

from pydantic import BaseModel, Field

from docling.datamodel.service.responses import *  # noqa: F403


class Provenance(BaseModel):
    page_num: int = Field(-1, description="Page number")
    l: float = Field(-1, description="Left border of bounding box")
    t: float = Field(-1, description="Top border of bounding box")
    r: float = Field(-1, description="Right border of bounding box")
    b: float = Field(-1, description="Bottom border of bounding box")
    charspan: Tuple[int, int] = Field(
        [0, 0], description="Character span of text within this doc item"
    )


class DocItem(BaseModel):
    self_ref: str = Field("", description="Element of page")
    prov: List[Provenance] = Field([], description="Provenance of chunk")


class ChunkResponse(BaseModel):
    chunk: str = Field("", description="Text of chunk")
    doc_items: List[DocItem] = Field([], description="Doc items within chunk")


class ChunkResponses(BaseModel):
    chunks: List[ChunkResponse] = Field([], description="Chunks in doc")
