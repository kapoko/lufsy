# EBU R128 Analyzer

Simple macOS drag-and-drop tool to analyze loudness using bundled FFmpeg.

## What it checks

- Integrated loudness target: `-23 LUFS` with `+-0.5 LU` tolerance.
- Maximum true peak: `<= -1.0 dBTP`.

These align with common EBU R128 broadcast guidance.

## How it works

- Drop audio/video files into the app window.
- Files appear in a list immediately.
- The Result column shows:
  - spinner while analyzing,
  - green checkmark when pass,
  - red x when fail.
- Multiple files are analyzed concurrently.

## Build and run

```bash
swift run
```
