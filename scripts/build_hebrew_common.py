#!/usr/bin/env python3
"""Список частых ивритских слов для автоконверсии (macos/Sources/RuSwitcher/HebrewCommonWords.swift).

  python3 scripts/build_hebrew_common.py [--src FILE] [--n 3000]

Зачем: системный словарь иврита принимает любые буквы, поэтому набранное на иврите нельзя
проверить, и образ частого слова в другой раскладке, если он оказался настоящим английским
словом («בוא» → «cut»), конвертировался. Список частых слов закрывает это: такое набранное
слово автоконверсия оставляет как есть.

Источник: FrequencyWords (Hermit Dave), OpenSubtitles 2018, данные под CC BY-SA 4.0 —
поэтому и сгенерированный файл под CC BY-SA 4.0 (сказано в его заголовке).
Берём N самых частых слов из ивритских букв длиной от трёх: короче детектор иврит не трогает.
"""
import argparse
import os
import re
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
URL = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/he/he_50k.txt"
OUT = os.path.join(ROOT, "macos", "Sources", "RuSwitcher", "HebrewCommonWords.swift")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.expanduser("~/Library/Caches/ruswitcher-dict-sources/he_50k.txt"))
    ap.add_argument("--n", type=int, default=3000)
    args = ap.parse_args()
    if not os.path.exists(args.src):
        os.makedirs(os.path.dirname(args.src), exist_ok=True)
        urllib.request.urlretrieve(URL, args.src)

    hebrew = re.compile(r"^[א-ת]{3,}$")
    words = []
    with open(args.src, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2 and hebrew.match(parts[0]) and parts[0] not in words:
                words.append(parts[0])
                if len(words) >= args.n:
                    break

    lines = []
    row = []
    for w in words:
        row.append(w)
        if len(row) == 12:
            lines.append(" ".join(row))
            row = []
    if row:
        lines.append(" ".join(row))
    body = "\n".join(lines)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(f'''// Сгенерировано scripts/build_hebrew_common.py, руками не править.
// Список слов взят из FrequencyWords (Hermit Dave), OpenSubtitles 2018, и распространяется
// под CC BY-SA 4.0: https://creativecommons.org/licenses/by-sa/4.0/

/// {len(words)} самых частых ивритских слов (от трёх букв). Системный словарь иврита принимает
/// любые буквы, поэтому набранное на иврите проверяем по этому списку: частое слово
/// автоконверсия не трогает, даже если его образ в другой раскладке — английское слово.
enum HebrewCommonWords {{
    private static let words: Set<Substring> = Set(text.split(whereSeparator: \\.isWhitespace))

    static func contains(_ word: String) -> Bool {{ words.contains(Substring(word)) }}

    private static let text = """
{body}
"""
}}
''')
    print(f"{len(words)} слов → {OUT}")


if __name__ == "__main__":
    main()
