#!/usr/bin/env python3
"""Record the real game chapter by chapter, mux narration, retain compact MP4s.

Usage: python3 tests/render_frontier_showcase.py [scene_id ...]
Generate narration first with artifacts/frontier/showcase/generate_narration.py.
No installed game configuration or player saves are changed.
"""
from pathlib import Path
import hashlib
import json
import math
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "artifacts/frontier/showcase"
GODOT = "/opt/homebrew/bin/godot"
FPS = 30


def run(args, log=None):
    if log:
        with open(log, "w") as handle:
            subprocess.run(args, stdout=handle, stderr=subprocess.STDOUT, check=True)
    else:
        subprocess.run(args, check=True)


def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)
    ]))


def isolated_project():
    target = Path(tempfile.mkdtemp(prefix="troop-video-project-"))
    for name in ["addons", "assets", "scenes", "scripts", "tests", ".godot", "icon.svg", "icon.svg.import"]:
        (target / name).symlink_to(ROOT / name, target_is_directory=(ROOT / name).is_dir())
    config = (ROOT / "project.godot").read_text()
    config = config.replace('window/stretch/mode="canvas_items"', 'window/stretch/mode="viewport"')
    config = config.replace('window/stretch/aspect="expand"', 'window/stretch/aspect="keep"')
    config = config.replace('window/dpi/allow_hidpi=false', 'window/dpi/allow_hidpi=false\nwindow/size/window_width_override=960\nwindow/size/window_height_override=540')
    config += '\n[editor]\n\nmovie_writer/video_quality=0.82\n'
    (target / "project.godot").write_text(config)
    return target


def record(scene, project):
    name = scene["id"]
    raw = OUT / f"{name}.avi"
    result = OUT / "clips" / f"{name}.mp4"
    log = OUT / "logs" / f"{name}.log"
    audio = OUT / "audio" / f"{name}.wav"
    if not audio.exists():
        raise RuntimeError(f"Narration missing: {audio}")
    duration = float(scene["duration"])
    frames = round(duration * FPS)
    print(f"RECORD {name}: {duration:.2f}s", flush=True)
    run([GODOT, "--path", str(project), "--write-movie", str(raw), "--fixed-fps", str(FPS),
         "--disable-vsync", "--", "frontiervideo", str(OUT / "narration.json"), name, str(duration)], log)
    text = log.read_text()
    if "save_unchanged=true" not in text or "SCRIPT ERROR" in text or "ERROR: Showcase" in text:
        raise RuntimeError(f"Capture validation failed. Inspect {log}")
    # Renderer shutdown warnings predate the showcase. A failed tutorial action
    # is different: do not silently publish footage claiming that it succeeded.
    for line in text.splitlines():
        if line.startswith("SHOWCASE_CLICK") and any(x in line for x in ["not enough", "Bring ", "cannot", "failed", "needs "]):
            raise RuntimeError(f"Rejected tutorial interaction: {line}")
    info = probe(raw)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    if (video["width"], video["height"]) != (1600, 900):
        raise RuntimeError(f"Unexpected viewport: {video['width']} x {video['height']}")
    start_frame = int(video["nb_frames"]) - frames
    if start_frame < 0:
        raise RuntimeError("Incomplete recording")
    start = start_frame / FPS
    filters = (
        f"[0:v]trim=start_frame={start_frame},setpts=PTS-STARTPTS,"
        f"fade=t=in:st=0:d=0.18,fade=t=out:st={duration-0.18}:d=0.18[v];"
        f"[0:a]atrim=start={start}:duration={duration},asetpts=PTS-STARTPTS,volume=0.08[game];"
        f"[1:a]adelay=450:all=1,apad,atrim=duration={duration},loudnorm=I=-18:TP=-2:LRA=9[voice];"
        "[game][voice]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[a]"
    )
    run(["ffmpeg", "-hide_banner", "-loglevel", "warning", "-y", "-i", str(raw), "-i", str(audio),
         "-filter_complex", filters, "-map", "[v]", "-map", "[a]", "-t", str(duration),
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "19", "-pix_fmt", "yuv420p",
         "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart", str(result)],
        OUT / "logs" / f"{name}-encode.log")
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", str(duration * 0.5),
         "-i", str(result), "-frames:v", "1", str(OUT / "frames" / f"{name}.png")])
    raw.unlink()  # Only this run's successfully encoded intermediate.
    print(f"DONE {name}: {result.stat().st_size / 1e6:.1f} MB", flush=True)


def assemble(scenes):
    clips = OUT / "clips.txt"
    clips.write_text("".join(f"file 'clips/{row['id']}.mp4'\nduration {row['duration']:.9f}\n" for row in scenes))
    metadata = [";FFMETADATA1", "title=TROOP - Roots & Rockets: Showcase and How to Play",
                "artist=TROOP", "comment=Actual game capture in a separate demonstration career. Local synthesized narration. Sky imagery: ESO/S. Brunier and NASA/GSFC."]
    cursor = 0.0
    chapter_rows = []
    for row in scenes:
        end = cursor + row["duration"]
        metadata.extend(["[CHAPTER]", "TIMEBASE=1/1000", f"START={round(cursor*1000)}", f"END={round(end*1000)}", f"title={row['title']}"])
        chapter_rows.append({"start": cursor, "title": row["title"], "controls": row["controls"]})
        cursor = end
    meta = OUT / "chapters.ffmetadata"
    meta.write_text("\n".join(metadata) + "\n")
    result = OUT / "TROOP-Roots-and-Rockets-Showcase.mp4"
    run(["ffmpeg", "-hide_banner", "-loglevel", "warning", "-y", "-f", "concat", "-safe", "0", "-i", str(clips),
         "-i", str(OUT / "subtitles.srt"), "-f", "ffmetadata", "-i", str(meta), "-map", "0:v:0", "-map", "0:a:0", "-map", "1:0",
         "-map_metadata", "2", "-map_chapters", "2", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
         "-af", "aresample=async=1:first_pts=0", "-c:s", "mov_text",
         "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=English narration", "-disposition:s:0", "0", "-movflags", "+faststart", str(result)], OUT / "logs" / "assembly.log")
    (OUT / "chapters.json").write_text(json.dumps(chapter_rows, indent=2))
    print(f"FINISHED {result} duration={cursor:.2f}s size={result.stat().st_size/1e6:.1f}MB", flush=True)


def main():
    scenes = json.loads((OUT / "narration.json").read_text())
    for name in ["clips", "frames", "logs"]:
        (OUT / name).mkdir(parents=True, exist_ok=True)
    selected = set(sys.argv[1:])
    if selected == {"assemble"}:
        assemble(scenes)
        return
    project = isolated_project()
    try:
        for scene in scenes:
            if not selected or scene["id"] in selected:
                record(scene, project)
    finally:
        # Remove only links and the temporary project file, never their targets.
        for entry in project.iterdir():
            if entry.is_symlink() or entry.is_file():
                entry.unlink()
        project.rmdir()
    if all((OUT / "clips" / f"{row['id']}.mp4").exists() for row in scenes):
        assemble(scenes)


if __name__ == "__main__":
    main()
