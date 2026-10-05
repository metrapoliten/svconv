import sys
from pathlib import Path

# Тесты импортируют модули tools/ напрямую.
sys.path.insert(0, str(Path(__file__).resolve().parent))
