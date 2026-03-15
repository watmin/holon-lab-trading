"""Algebraic feature selection via reward/punishment loops.

Tracks per-indicator importance as an EMA. The critic calls update() after
each batch of scored decisions. Fields that consistently contribute to
correct predictions get boosted; fields that add noise get pruned.
"""

from __future__ import annotations

import json
from pathlib import Path


class FeatureDarwinism:
    """Track and evolve per-field importance weights."""

    def __init__(
        self,
        field_names: list[str],
        ema_alpha: float = 0.3,
        prune_threshold: float = 0.15,
    ):
        self.ema_alpha = ema_alpha
        self.prune_threshold = prune_threshold
        self.importance: dict[str, float] = {f: 0.5 for f in field_names}
        self.weights: dict[str, float] = {f: 1.0 for f in field_names}

    def update(
        self,
        surprise_profile: dict[str, float],
        realized_return: float,
        action: str,
    ) -> None:
        """Update field importance from a single scored decision.

        Args:
            surprise_profile: per-field surprise from the engram/subspace
            realized_return: actual return of the next candle
            action: "BUY", "SELL", or "HOLD"
        """
        direction_correct = (
            (action == "BUY" and realized_return > 0)
            or (action == "SELL" and realized_return < 0)
        )

        for field, surprise in surprise_profile.items():
            if field not in self.importance:
                continue

            fitness = (1.0 - surprise)  # low surprise = good fit
            if direction_correct:
                delta = fitness * 0.1
            else:
                delta = -fitness * 0.1

            old = self.importance[field]
            self.importance[field] = (
                (1 - self.ema_alpha) * old + self.ema_alpha * (old + delta)
            )

            self.weights[field] = max(0.01, self.weights[field] + delta * 0.05)

    def get_weights(self) -> dict[str, float]:
        """Current weights, excluding pruned fields."""
        return {f: w for f, w in self.weights.items() if w >= self.prune_threshold}

    def pruned_fields(self) -> list[str]:
        return [f for f, w in self.weights.items() if w < self.prune_threshold]

    def report(self) -> str:
        """Human-readable ranked importance table."""
        ranked = sorted(self.importance.items(), key=lambda x: x[1], reverse=True)
        lines = ["=== Feature Importance (Algebraic Darwinism) ==="]
        for field, score in ranked:
            weight = self.weights.get(field, 0.0)
            status = "PRUNED" if weight < self.prune_threshold else "active"
            lines.append(f"  {field:18s}  importance={score:.3f}  weight={weight:.3f}  [{status}]")
        return "\n".join(lines)

    def save(self, path: str = "data/feature_weights.json") -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as f:
            json.dump(
                {"importance": self.importance, "weights": self.weights},
                f,
                indent=2,
            )

    @classmethod
    def load(cls, path: str) -> FeatureDarwinism:
        with open(path) as f:
            data = json.load(f)
        obj = cls(list(data["importance"].keys()))
        obj.importance = data["importance"]
        obj.weights = data["weights"]
        return obj
