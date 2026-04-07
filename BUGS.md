# Bugs

## Validation Debt

- Full end-to-end validation is still required ASAP.
- The focused suites now cover modal button clicks and `mlx_audio` generator-shaped outputs, but the project still lacks a true fresh-process smoke test for the real TTS path.
- Recommended next validation task:
  - Launch a fresh `lilt` process.
  - Add a short source.
  - Play a short clip through the real `mlx-audio` stack.
  - Confirm audio playback, pause/resume, stop, and TUI status updates without mocks.
