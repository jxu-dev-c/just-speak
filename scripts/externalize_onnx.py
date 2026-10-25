"""Rewrite Fun-ASR-Nano ONNX models so their weights live in page-aligned `<name>.data` side files.

onnxruntime memory-maps page-aligned external initializers instead of copying them onto the heap,
which cuts the loaded footprint from ~2.2 GB to ~0.9 GB with identical output and speed.
sherpa-onnx only loads the LLM by path (required for external data) when `<name>.data` exists.

Usage: python externalize_onnx.py SRC_MODEL_DIR DST_MODEL_DIR
"""
import os
import shutil
import sys

import onnx
from onnx.external_data_helper import set_external_data

ALIGN = 1 << 16  # 64 KiB: a multiple of the 16 KiB arm64 page size
MODELS = ["embedding.int8.onnx", "encoder_adaptor.int8.onnx", "llm.int8.onnx"]


def externalize(src: str, dst_dir: str, min_bytes: int = 1024) -> None:
    m = onnx.load(src)
    data_name = os.path.splitext(os.path.basename(src))[0] + ".data"
    with open(os.path.join(dst_dir, data_name), "wb") as f:
        for t in m.graph.initializer:
            if not t.HasField("raw_data") or len(t.raw_data) < min_bytes:
                continue
            f.write(b"\0" * ((-f.tell()) % ALIGN))
            offset = f.tell()
            f.write(t.raw_data)
            set_external_data(t, location=data_name, offset=offset, length=len(t.raw_data))
            t.ClearField("raw_data")
            t.data_location = onnx.TensorProto.EXTERNAL
    onnx.save(m, os.path.join(dst_dir, os.path.basename(src)))


def main() -> None:
    src_dir, dst_dir = sys.argv[1], sys.argv[2]
    tmp = dst_dir + ".partial"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    for name in MODELS:
        print(f"    {name}", flush=True)
        externalize(os.path.join(src_dir, name), tmp)
    for extra in ["Qwen3-0.6B", "test_wavs"]:
        if os.path.isdir(os.path.join(src_dir, extra)):
            shutil.copytree(os.path.join(src_dir, extra), os.path.join(tmp, extra))
    os.replace(tmp, dst_dir)


if __name__ == "__main__":
    main()
