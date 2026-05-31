from __future__ import annotations

class TopicCluster:
    def __init__(self, name: str, members: list[int]) -> None:
        self.name = name
        self.members = members

    def references(self) -> list[int]:
        return list(self.members)

TOPIC_CLUSTERS = [
    TopicCluster(name='blocked', members=[0, 1, 4, 5, 6, 7, 8]),
    TopicCluster(name='goal', members=[0, 1, 3, 4, 5, 6, 7, 8]),
    TopicCluster(name='work', members=[0, 1, 3, 4, 5, 6, 7, 8]),
]
