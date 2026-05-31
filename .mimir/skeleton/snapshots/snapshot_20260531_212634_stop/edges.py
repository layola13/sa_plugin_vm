from __future__ import annotations

from .nodes import NODES
from .topics import TOPIC_CLUSTERS
from .files import FILE_REFERENCES
from .patterns import REPEATED_PATTERNS

class RelationGraph:
    memory_count = 10

    topic_clusters = TOPIC_CLUSTERS
    file_references = FILE_REFERENCES
    repeated_patterns = REPEATED_PATTERNS

    co_occurrences = [{'left': 'blocked', 'right': 'goal', 'count': 7}, {'left': 'blocked', 'right': 'work', 'count': 7}, {'left': 'goal', 'right': 'work', 'count': 8}]
    hard_edges = [{'source': 0, 'target': 1, 'relation': 'follows_from', 'label': None}, {'source': 4, 'target': 5, 'relation': 'follows_from', 'label': None}, {'source': 5, 'target': 6, 'relation': 'follows_from', 'label': None}, {'source': 6, 'target': 7, 'relation': 'follows_from', 'label': None}, {'source': 7, 'target': 8, 'relation': 'follows_from', 'label': None}]

    def same_topic_neighbors(self, node_index: int) -> list[tuple[int, str]]:
        neighbors: list[tuple[int, str]] = []
        seen: set[tuple[int, str]] = set()
        for cluster in self.topic_clusters:
            if node_index not in cluster.members:
                continue
            for member in cluster.members:
                if member == node_index:
                    continue
                item = (member, cluster.name)
                if item in seen:
                    continue
                seen.add(item)
                neighbors.append(item)
        return neighbors

    def same_file_neighbors(self, node_index: int) -> list[tuple[int, str]]:
        neighbors: list[tuple[int, str]] = []
        seen: set[tuple[int, str]] = set()
        for reference in self.file_references:
            if node_index not in reference.members:
                continue
            for member in reference.members:
                if member == node_index:
                    continue
                item = (member, reference.path)
                if item in seen:
                    continue
                seen.add(item)
                neighbors.append(item)
        return neighbors

    def same_pattern_neighbors(self, node_index: int) -> list[tuple[int, str]]:
        neighbors: list[tuple[int, str]] = []
        seen: set[tuple[int, str]] = set()
        for pattern in self.repeated_patterns:
            if node_index not in pattern.members:
                continue
            for member in pattern.members:
                if member == node_index:
                    continue
                item = (member, pattern.name)
                if item in seen:
                    continue
                seen.add(item)
                neighbors.append(item)
        return neighbors

    def neighbors(self, node_index: int) -> list[tuple[int, str, str | None]]:
        merged: list[tuple[int, str, str | None]] = []
        seen: set[tuple[int, str, str | None]] = set()
        for edge in self.hard_edges:
            if edge['source'] == node_index:
                item = (edge['target'], edge['relation'], edge['label'])
                if item not in seen:
                    seen.add(item)
                    merged.append(item)
            elif edge['target'] == node_index:
                item = (edge['source'], edge['relation'], edge['label'])
                if item not in seen:
                    seen.add(item)
                    merged.append(item)
        for neighbor, label in self.same_topic_neighbors(node_index):
            item = (neighbor, 'same_topic_as', label)
            if item not in seen:
                seen.add(item)
                merged.append(item)
        for neighbor, label in self.same_file_neighbors(node_index):
            item = (neighbor, 'mentions_same_file', label)
            if item not in seen:
                seen.add(item)
                merged.append(item)
        for neighbor, label in self.same_pattern_neighbors(node_index):
            item = (neighbor, 'repeats_pattern', label)
            if item not in seen:
                seen.add(item)
                merged.append(item)
        return merged

    def topics_for(self, node_index: int) -> list[str]:
        return [cluster.name for cluster in self.topic_clusters if node_index in cluster.members]

    def files_for(self, node_index: int) -> list[str]:
        return [reference.path for reference in self.file_references if node_index in reference.members]

    def repeated_types(self) -> list[str]:
        return [pattern.name for pattern in self.repeated_patterns]
