"""Bridge a recorded audio file to ConnectOnion's official transcribe API."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

DEFAULT_TRANSCRIPTION_MODEL = "co/gemini-2.5-flash"


def transcription_model() -> str:
    configured_model = os.environ.get("CONNECTONION_TRANSCRIPTION_MODEL", "").strip()
    return configured_model or DEFAULT_TRANSCRIPTION_MODEL


def main(audio_path: str, output_path: str) -> None:
    from connectonion import transcribe

    model = transcription_model()
    try:
        text = transcribe(audio_path, model=model)
    except KeyError as error:
        if error.args != ("content",):
            raise
        raise RuntimeError(
            "ConnectOnion returned no transcription text "
            f"for model {model}. Set CONNECTONION_TRANSCRIPTION_MODEL "
            "to another audio-capable model and try again."
        ) from None

    Path(output_path).write_text(
        json.dumps({"text": text}, ensure_ascii=False),
        encoding="utf-8",
    )


def cli() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: transcribe_audio.py AUDIO_PATH OUTPUT_PATH")
    try:
        main(sys.argv[1], sys.argv[2])
    except Exception as error:
        message = str(error).strip() or error.__class__.__name__
        print(message, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    cli()
