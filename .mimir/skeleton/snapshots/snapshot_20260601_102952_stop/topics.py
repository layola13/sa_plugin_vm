from __future__ import annotations

class TopicCluster:
    def __init__(self, name: str, members: list[int]) -> None:
        self.name = name
        self.members = members

    def references(self) -> list[int]:
        return list(self.members)

TOPIC_CLUSTERS = [
    TopicCluster(name='crash', members=[0, 1, 2]),
    TopicCluster(name='goal', members=[0, 2, 4, 5]),
    TopicCluster(name='parser', members=[1, 5]),
    TopicCluster(name='work', members=[0, 4]),
]
