import importlib.util
import io
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "transcribe_audio.py"


class TranscribeAudioTests(unittest.TestCase):
    def test_main_uses_connectonion_transcribe_and_writes_json(self):
        calls = []
        fake_connectonion = types.ModuleType("connectonion")

        def fake_transcribe(audio_path, *, model):
            calls.append((audio_path, model))
            return "你好，ConnectOnion"

        fake_connectonion.transcribe = fake_transcribe
        spec = importlib.util.spec_from_file_location(
            "transcribe_audio_under_test",
            SCRIPT_PATH,
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        with tempfile.TemporaryDirectory() as directory:
            output_path = Path(directory) / "result.json"
            with patch.dict(sys.modules, {"connectonion": fake_connectonion}):
                module.main("recording.m4a", str(output_path))

            self.assertEqual(
                calls,
                [("recording.m4a", "co/gemini-2.5-flash")],
            )
            self.assertEqual(
                json.loads(output_path.read_text(encoding="utf-8")),
                {"text": "你好，ConnectOnion"},
            )

    def test_cli_reports_transcription_error_without_traceback(self):
        fake_connectonion = types.ModuleType("connectonion")

        def failing_transcribe(_audio_path, *, model):
            self.assertEqual(model, "co/gemini-2.5-flash")
            raise ValueError("Invalid audio format")

        fake_connectonion.transcribe = failing_transcribe
        spec = importlib.util.spec_from_file_location(
            "transcribe_audio_error_under_test",
            SCRIPT_PATH,
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        standard_error = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            output_path = Path(directory) / "result.json"
            with patch.dict(sys.modules, {"connectonion": fake_connectonion}), patch.object(
                sys,
                "argv",
                [str(SCRIPT_PATH), "recording.wav", str(output_path)],
            ), patch("sys.stderr", standard_error):
                with self.assertRaises(SystemExit) as raised:
                    module.cli()

        self.assertEqual(raised.exception.code, 1)
        self.assertEqual(standard_error.getvalue(), "Invalid audio format\n")

    def test_main_allows_transcription_model_override(self):
        calls = []
        fake_connectonion = types.ModuleType("connectonion")

        def fake_transcribe(audio_path, *, model):
            calls.append((audio_path, model))
            return "override transcript"

        fake_connectonion.transcribe = fake_transcribe
        spec = importlib.util.spec_from_file_location(
            "transcribe_audio_override_under_test",
            SCRIPT_PATH,
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        with tempfile.TemporaryDirectory() as directory:
            output_path = Path(directory) / "result.json"
            with patch.dict(sys.modules, {"connectonion": fake_connectonion}), patch.dict(
                "os.environ",
                {"CONNECTONION_TRANSCRIPTION_MODEL": "co/gemini-2.5-pro"},
            ):
                module.main("recording.wav", str(output_path))

        self.assertEqual(
            calls,
            [("recording.wav", "co/gemini-2.5-pro")],
        )

    def test_cli_explains_missing_content_response(self):
        fake_connectonion = types.ModuleType("connectonion")

        def failing_transcribe(_audio_path, *, model):
            self.assertEqual(model, "co/gemini-2.5-flash")
            raise KeyError("content")

        fake_connectonion.transcribe = failing_transcribe
        spec = importlib.util.spec_from_file_location(
            "transcribe_audio_content_error_under_test",
            SCRIPT_PATH,
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        standard_error = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            output_path = Path(directory) / "result.json"
            with patch.dict(sys.modules, {"connectonion": fake_connectonion}), patch.object(
                sys,
                "argv",
                [str(SCRIPT_PATH), "recording.wav", str(output_path)],
            ), patch("sys.stderr", standard_error):
                with self.assertRaises(SystemExit) as raised:
                    module.cli()

        self.assertEqual(raised.exception.code, 1)
        self.assertEqual(
            standard_error.getvalue(),
            "ConnectOnion returned no transcription text for model "
            "co/gemini-2.5-flash. Set CONNECTONION_TRANSCRIPTION_MODEL "
            "to another audio-capable model and try again.\n",
        )

    def test_main_reraises_unrelated_key_errors(self):
        fake_connectonion = types.ModuleType("connectonion")
        def unexpected_key_error(_audio_path, *, model):
            raise KeyError("unexpected")

        fake_connectonion.transcribe = unexpected_key_error
        module = self.load_module("transcribe_audio_unrelated_key_error")

        with patch.dict(sys.modules, {"connectonion": fake_connectonion}):
            with self.assertRaisesRegex(KeyError, "unexpected"):
                module.main("recording.wav", "unused.json")

    def test_cli_requires_audio_and_output_paths(self):
        module = self.load_module("transcribe_audio_missing_arguments")

        with patch.object(sys, "argv", [str(SCRIPT_PATH)]):
            with self.assertRaises(SystemExit) as raised:
                module.cli()

        self.assertEqual(
            raised.exception.code,
            "usage: transcribe_audio.py AUDIO_PATH OUTPUT_PATH",
        )

    @staticmethod
    def load_module(name):
        spec = importlib.util.spec_from_file_location(name, SCRIPT_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module


if __name__ == "__main__":
    unittest.main()
