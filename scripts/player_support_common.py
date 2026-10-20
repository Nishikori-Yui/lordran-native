"""Local workspace helpers shared by player support commands."""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def profile():
    sys.path.insert(0, str(REPO / "dm/games"))
    import game
    return game.load()


def private_path(path):
    path = Path(path).expanduser().resolve()
    if not path.is_relative_to((REPO / "game").resolve()):
        raise ValueError("Keep generated support files and packaging inputs under this checkout's game/ directory")
    return path


def print_json(value):
    import json
    print(json.dumps(value, indent=2, ensure_ascii=True))
