"""Позволяет pytest импортировать svconv_model при запуске из корня репозитория."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
