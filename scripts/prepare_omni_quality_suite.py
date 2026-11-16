#!/usr/bin/env python3
"""Create a labeled local quality suite from public human speech and local TTS."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import wave

import numpy as np
import pyarrow.parquet as parquet
import soundfile


def write_wav(path: Path, samples):
    soundfile.write(path, samples, 16000, subtype="PCM_16")
    return len(samples) / 16000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    arguments = parser.parse_args()
    root = arguments.directory
    source = json.loads((root / "librispeech-source.json").read_text())
    rows = parquet.read_table(root / "librispeech.parquet").to_pylist()
    decoded = []
    for row in rows:
        samples, rate = soundfile.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32")
        if rate != 16000 or samples.ndim != 1:
            raise ValueError("Unexpected public corpus audio format")
        decoded.append((row["id"], samples, row["text"]))
    cases = []
    hints = json.loads((root / "priority-hints.json").read_text())
    for layer, minimum, maximum in [("short", 5, 15), ("medium", 35, 60), ("long", 125, 300)]:
        for index in range(4):
            chosen = []
            seconds = 0
            offset = index * 13
            for position in range(len(decoded)):
                identifier, samples, text = decoded[(offset + position) % len(decoded)]
                if layer == "short" and not minimum <= len(samples) / 16000 <= maximum:
                    continue
                if seconds + len(samples) / 16000 + (0.4 if chosen else 0) > maximum:
                    continue
                chosen.append((identifier, samples, text))
                seconds += len(samples) / 16000 + (0.4 if len(chosen) > 1 else 0)
                if seconds >= minimum:
                    break
            if not minimum <= seconds <= maximum:
                raise ValueError("Human sample duration outside the frozen layer")
            samples = []
            for part, (_, audio, _) in enumerate(chosen):
                if part:
                    samples.append(np.zeros(6400, dtype="float32"))
                samples.append(audio)
            name = f"human-{layer}-{index + 1}"
            duration = write_wav(root / f"{name}.wav", np.concatenate(samples))
            cases.append({"id": name, "audio": name + ".wav", "kind": "human-reading" if len(chosen) == 1 else "human-reading-assembled", "layer": layer, "language": "en", "durationSeconds": duration, "reference": " ".join(item[2] for item in chosen), "referenceKind": "source-published-transcript", "sourceClipIDs": [item[0] for item in chosen], "source": source["repo"] + "@" + source["revision"]})

    # Fictional fixtures only; never seed this corpus from a real address book.
    short = [
        "请用 pstack 评审 SmartShadow，先暂缓发布；只改设置页，保留原有整段润色流程。",
        "请把顾清禾、陶星澜和周远舟的名字写准确，今天下午三点讨论。",
        "这幅画的 smart shade 是普通阴影，诊断结果写进报告，保留原来的英文。",
        "会议从周二改为周三，预算改为三千五百元，先保存草稿，等确认再发送。",
    ]
    paragraphs = [
        "第一项任务是检查当前设置页中的账户状态。请核对登录是否有效，保留已有模型和词库内容，所有变化都应当有明确的版本记录。",
        "第二项任务是整理语音输入的测试材料。中文和英文要分别统计，姓名和工程术语需要单独核对，普通词语继续保留原意。",
        "第三项任务只修改本地转写流程。原始录音需要完整保存，停录之后检查末尾内容，失败时保留材料以便重新识别。",
        "第四项任务使用 pstack 评审 SmartShadow。请保留完整上下文和前面的限制条件，先暂缓发布，等整个方案核对完成再讨论上线。",
        "第五项任务需要联系顾清禾、陶星澜和周远舟。这三个人的名字请按照已有词库准确书写，先把消息保存为草稿，等待人工确认。",
        "第六项任务检查 OpenClaw 的连接状态。请先看日志中的错误分类，再核对最近一次成功请求，保留当前会话和已经完成的工作。",
        "第七项任务调整会议安排。原定下周二上午十点改为下周三下午三点，预算从三千元改为三千五百元，请以最后这组时间和金额为准。",
        "第八项任务保留这幅画的普通阴影，英文原文是 smart shade。诊断结果属于独立报告，原来已经确认的内容继续保存。",
        "第九项任务验证长段录音的分段接缝。每段文字都应当有对应的音频范围，所有必要需求完整保留，相同内容在最终输入框中只出现一次。",
        "第十项任务检查取消和恢复。按下取消之后结束当前执行，重新开始使用新的会话，已经保存的录音仍然可以从历史记录中查看。",
        "第十一项任务核对文字插入。请在实际编辑框中观察全文，记录停录到出现文字的总等待，没有编辑目标时把结果留在剪贴板。",
        "第十二项任务只记录匿名耗时和成功状态。真实姓名清单继续保留在本机，模型的下载来源和实际版本应当写入验收记录。",
        "刚才第四项中的发布安排撤回，最终决定继续暂缓发布。第七项中的时间和预算保持最后一次修改的结果，其他任务与限制条件全部保留。",
        "最后请按原始需求核对所有条目。先完成测试，再核对安装版的实际表现。把发现的问题记录清楚，当前应用保持正常运行。",
    ]
    for layer in ("short", "medium", "long"):
        for index in range(4):
            text = short[index] if layer == "short" else "".join(paragraphs[index:index + 3] if layer == "medium" else paragraphs[index:] + paragraphs[:index])
            name = f"synthetic-{layer}-{index + 1}"
            input_path = root / f"{name}.txt"
            input_path.write_text(text)
            aiff = root / f"{name}.aiff"
            subprocess.run(["say", "-v", "Tingting", "-r", "200", "-f", str(input_path), "-o", str(aiff)], check=True)
            destination = root / f"{name}.wav"
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(destination)], check=True)
            with wave.open(str(destination)) as audio:
                duration = audio.getnframes() / audio.getframerate()
            cases.append({"id": name, "audio": name + ".wav", "kind": "local-Tingting-TTS", "layer": layer, "language": "zh", "durationSeconds": duration, "reference": text, "referenceKind": "synthesis-input-pronunciation-requires-review", "source": "local macOS say; local evaluation only"})
    for case in cases:
        case["sha256"] = hashlib.sha256((root / case["audio"]).read_bytes()).hexdigest()
    suite = {"schemaVersion": 1, "hints": hints["hints"], "configSnapshotSHA256": hints["configSnapshotSHA256"], "qualityStatus": "candidate corpus; TTS pronunciation and target duration ranges require review before adoption", "cases": cases}
    (root / "suite.json").write_text(json.dumps(suite, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"cases": len(cases), "durationByCase": {case["id"]: round(case["durationSeconds"], 2) for case in cases}}, indent=2))


if __name__ == "__main__":
    main()
