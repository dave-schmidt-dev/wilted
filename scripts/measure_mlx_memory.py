#!/usr/bin/env python3
"""Measure actual GPU/unified memory usage when loading and unloading MLX models.

Run this script on Apple Silicon hardware to profile how much Metal memory each
model consumes after loading and how much is reclaimed after unloading. Results
are printed as a table and depend heavily on system state (other processes, OS
caches, etc.).
"""

import gc

import mlx.core as mx


def measure_model(model_id: str, loader_fn) -> dict:
    """Load a model, measure memory before and after, then unload and measure again.

    Args:
        model_id: Human-readable identifier for the model.
        loader_fn: Zero-argument callable that loads and returns the model object.

    Returns:
        Dict with keys: model_id, before_mb, loaded_mb, after_unload_mb, delta_mb.
        All memory values are in megabytes (float).
    """
    before = mx.metal.get_active_memory()

    model = loader_fn()

    loaded = mx.metal.get_active_memory()

    del model
    gc.collect()
    mx.metal.clear_cache()

    after_unload = mx.metal.get_active_memory()

    def to_mb(b):
        return round(b / 1024 / 1024, 1)

    return {
        "model_id": model_id,
        "before_mb": to_mb(before),
        "loaded_mb": to_mb(loaded),
        "after_unload_mb": to_mb(after_unload),
        "delta_mb": to_mb(loaded - before),
    }


def main() -> None:
    """Attempt to measure memory for each supported model and print a results table."""
    results = []

    # Kokoro TTS
    try:
        from mlx_audio.tts.kokoro import KokoroTTS  # type: ignore

        results.append(
            measure_model(
                "Kokoro 82M",
                lambda: KokoroTTS("mlx-community/Kokoro-82M-bf16"),
            )
        )
    except ImportError:
        print("Skipping Kokoro: mlx_audio not installed")

    # Parakeet 1.1B ASR
    try:
        import parakeet_mlx  # type: ignore

        results.append(
            measure_model(
                "Parakeet 1.1B",
                lambda: parakeet_mlx.from_pretrained("mlx-community/parakeet-tdt-1.1b"),
            )
        )
    except ImportError:
        print("Skipping Parakeet: parakeet_mlx not installed")

    # Gemma 4 E2B (small vision-language model)
    try:
        import mlx_vlm  # type: ignore

        results.append(
            measure_model(
                "Gemma 4 E2B 4bit",
                lambda: mlx_vlm.load("mlx-community/gemma-4-e2b-it-4bit"),
            )
        )
    except ImportError:
        print("Skipping Gemma 4 E2B: mlx_vlm not installed")

    # Gemma 4 12B (larger vision-language model)
    try:
        import mlx_vlm  # type: ignore

        results.append(
            measure_model(
                "Gemma 4 12B 4bit",
                lambda: mlx_vlm.load("mlx-community/gemma-4-12b-a4b-it-4bit"),
            )
        )
    except ImportError:
        print("Skipping Gemma 4 12B: mlx_vlm not installed")

    if not results:
        print("No models could be measured. Install mlx_audio, parakeet_mlx, or mlx_vlm.")
        return

    # Print results table
    col_widths = [20, 12, 12, 12, 12]
    headers = ["Model", "Before(MB)", "Loaded(MB)", "After(MB)", "Delta(MB)"]
    divider = "-" * (sum(col_widths) + len(col_widths) - 1)

    print()
    print(divider)
    header_row = "  ".join(h.ljust(w) for h, w in zip(headers, col_widths))
    print(header_row)
    print(divider)

    for r in results:
        row = "  ".join(
            [
                r["model_id"].ljust(col_widths[0]),
                str(r["before_mb"]).ljust(col_widths[1]),
                str(r["loaded_mb"]).ljust(col_widths[2]),
                str(r["after_unload_mb"]).ljust(col_widths[3]),
                str(r["delta_mb"]).ljust(col_widths[4]),
            ]
        )
        print(row)

    print(divider)
    print()
    print("Results depend on system state. Run on target hardware.")


if __name__ == "__main__":
    main()
