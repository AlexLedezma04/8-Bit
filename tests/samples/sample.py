#!/usr/bin/env python3
"""A module."""

import os


@dataclass
class Point:
    x: int = 0

    def norm(self) -> float:
        return (self.x ** 2) ** 0.5  # length


print(len(os.listdir(".")), True, None)
