from __future__ import annotations

class PatternGroup:
    def __init__(self, name: str, members: list[int]) -> None:
        self.name = name
        self.members = members

    def repeats(self) -> list[int]:
        return list(self.members)

REPEATED_PATTERNS = [
    PatternGroup(name='decision', members=[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
]
