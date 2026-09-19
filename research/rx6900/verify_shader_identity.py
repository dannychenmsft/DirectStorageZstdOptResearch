"""Compare manifest-anchored GPU programs, allowing only relocated debug filenames."""
import argparse
import hashlib
import json
import pathlib
import re
import struct


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load_arm(root, arm):
    manifest_path = root / "arms" / arm / "arm.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    binaries = {}
    for item in manifest["files"]:
        data = (manifest_path.parent / item["name"]).read_bytes()
        if sha(data).lower() != item["sha256"].lower():
            raise ValueError(f"{arm}: runtime hash mismatch {item['name']}")
        binaries[item["name"]] = data
    programs = {}
    for item in manifest["shaders"]:
        path = pathlib.Path(manifest["sourceRoot"]) / "zstd" / "x64" / "Release" / "Shaders" / item["name"]
        header = path.read_bytes()
        if sha(header).lower() != item["sha256"].lower():
            raise ValueError(f"{arm}: header no longer matches immutable manifest: {path}")
        array = header.decode().split("const unsigned char ", 1)[1].split("{", 1)[1].split("}", 1)[0]
        data = bytes(int(value, 16) for value in re.findall(r"0x([0-9a-fA-F]{2})", array))
        if data[:4] != b"DXBC" or struct.unpack_from("<I", data, 24)[0] != len(data):
            raise ValueError(f"Invalid DXBC container: {path}")
        if data not in binaries["zstdgpu_demo.exe"]:
            raise ValueError(f"{arm}: generated shader not embedded in immutable demo: {path}")
        count = struct.unpack_from("<I", data, 28)[0]
        chunks = {}
        for offset in struct.unpack_from("<" + "I" * count, data, 32):
            tag = data[offset:offset + 4].decode("ascii")
            size = struct.unpack_from("<I", data, offset + 4)[0]
            payload = data[offset + 8:offset + 8 + size]
            if tag in chunks or len(payload) != size:
                raise ValueError(f"Invalid or duplicate chunk {tag}: {path}")
            chunks[tag] = payload
        if "DXIL" not in chunks:
            raise ValueError(f"Missing executable DXIL: {path}")
        programs[item["name"]] = (data, chunks)
    return manifest, sha(manifest_path.read_bytes()), programs


def compare(root, old, new):
    om, oh, op = load_arm(root, old)
    nm, nh, np = load_arm(root, new)
    if op.keys() != np.keys():
        raise ValueError("Shader set changed")
    results = []
    for name in sorted(op):
        od, oc = op[name]
        nd, nc = np[name]
        if oc.keys() != nc.keys():
            raise ValueError(f"Chunk set changed: {name}")
        different = [tag for tag in oc if oc[tag] != nc[tag]]
        if any(tag != "ILDN" for tag in different):
            raise ValueError(f"Non-debug-filename shader change: {name}: {different}")
        debug = {}
        for label, manifest, chunks in (("old", om, oc), ("new", nm, nc)):
            payload = chunks.get("ILDN", b"")
            if payload:
                flags, size = struct.unpack_from("<HH", payload)
                path = payload[4:4 + size].decode("utf-8")
                source_root = manifest["sourceRoot"].replace("\\", "/").lower()
                normalized = path.replace("\\", "/").lower()
                if not normalized.startswith(source_root + "/"):
                    raise ValueError(f"Unexpected debug path outside source root: {path}")
                debug[label] = {"flags": flags, "path": path, "relative": normalized[len(source_root):]}
        if debug and (debug["old"]["flags"], debug["old"]["relative"]) != (
                debug["new"]["flags"], debug["new"]["relative"]):
            raise ValueError(f"Debug filename change beyond worktree relocation: {name}")
        results.append({
            "shader": name, "oldContainerSha256": sha(od), "newContainerSha256": sha(nd),
            "fullContainerEqual": od == nd, "differentChunks": different, "debugFilename": debug,
            "identicalChunkSha256": {tag: sha(oc[tag]) for tag in oc if tag != "ILDN"},
        })
    return {
        "oldArm": old, "newArm": new, "oldCommit": om["commit"], "newCommit": nm["commit"],
        "oldManifestSha256": oh, "newManifestSha256": nh, "shaderCount": len(results),
        "allExecutableAndRuntimeChunksEqual": True, "allShadersEmbeddedInImmutableDemos": True,
        "onlyPermittedDifference": "ILDN debug filename source-root relocation",
        "shaders": results,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    result = [compare(args.root, "baseline", "baselinefixed"),
              compare(args.root, "e4-c4b3725", "e4fixed-4777371")]
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    for pair in result:
        print(f"{pair['oldArm']} -> {pair['newArm']}: {pair['shaderCount']} GPU programs identical")
