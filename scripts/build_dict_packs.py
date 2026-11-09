#!/usr/bin/env python3
"""Сборка скачиваемых частотных словарей RuSwitcher (каталог dicts/).

  python3 scripts/build_dict_packs.py [--src DIR] [--version N] [--ru N] [--en N]

Источник: FrequencyWords (Hermit Dave), списки OpenSubtitles 2018. Данные там под
CC BY-SA 4.0, поэтому и паки распространяются под CC BY-SA 4.0 (dicts/LICENSE).
Код приложения это не затрагивает: паки не входят в сборку, их скачивают отдельно.

Пак — словоформы языка в нижнем регистре, по одной на строку, отсортированные по
байтам UTF-8 (приложение ищет в них двоичным поиском), сжатые raw DEFLATE.
Короче трёх букв слов нет: двухбуквенные решает ShortWords, однобуквенные не трогаем.
Растянутые «ууу», «eee» (буква трижды подряд) — шум субтитров, отбрасываем.
В русском отбрасываем и невозможное по орфографии («мьы», «асдеьэ» — это набор не в той
раскладке): ь/ъ/ы в начале слова, ь/ъ после гласной или перед ь/ъ/ы.

Размер выбран стендом автоконверсии: ru 50 тыс. и en 30 тыс. дают всю полноту, которую
видно на корпусе; большие паки добавляют только ложные срабатывания на мусоре субтитров.
"""
import argparse
import hashlib
import json
import os
import re
import urllib.request
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE_URL = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/{lang}/{lang}_full.txt"
LANGS = {
    "ru": re.compile(r"^[а-яё]{3,}$"),
    "en": re.compile(r"^[a-z][a-z']*[a-z]$"),
}


def source_lines(lang, src_dir):
    path = os.path.join(src_dir, f"{lang}_full.txt")
    if not os.path.exists(path):
        os.makedirs(src_dir, exist_ok=True)
        print(f"  скачиваю {lang}_full.txt…")
        urllib.request.urlretrieve(SOURCE_URL.format(lang=lang), path)
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                yield parts[0], int(parts[1])


def build(lang, n, src_dir):
    pattern, words = LANGS[lang], []
    stretched = re.compile(r"(.)\1\1")
    impossible = re.compile(r"^[ьъы]|[аеёиоуыэюя][ьъ]|[ьъ][ьъы]") if lang == "ru" else None
    for w, _ in source_lines(lang, src_dir):
        if len(w) >= 3 and pattern.match(w) and not stretched.search(w) \
                and not (impossible and impossible.search(w)):
            words.append(w)
            if len(words) >= n:
                break
    words = sorted(set(words), key=lambda w: w.encode("utf-8"))
    return words


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.expanduser("~/Library/Caches/ruswitcher-dict-sources"))
    ap.add_argument("--out", default=os.path.join(ROOT, "dicts"))
    ap.add_argument("--version", type=int, default=1)
    ap.add_argument("--ru", type=int, default=50000)
    ap.add_argument("--en", type=int, default=30000)
    ap.add_argument("--plain", help="ещё и распакованные паки сюда (для стенда)")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    packs = []
    for lang, n in (("en", args.en), ("ru", args.ru)):
        words = build(lang, n, args.src)
        text = ("\n".join(words) + "\n").encode("utf-8")
        comp = zlib.compressobj(9, zlib.DEFLATED, -15)
        blob = comp.compress(text) + comp.flush()
        name = f"{lang}.v{args.version}.deflate"
        with open(os.path.join(args.out, name), "wb") as f:
            f.write(blob)
        if args.plain:
            os.makedirs(args.plain, exist_ok=True)
            with open(os.path.join(args.plain, f"{lang}.dict"), "wb") as f:
                f.write(text)
        packs.append({
            "lang": lang, "version": args.version, "count": len(words), "file": name,
            "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest(),
        })
        print(f"  {name}: {len(words)} слов, {len(text) // 1024} КБ → {len(blob) // 1024} КБ")

    manifest = {
        "format": 1,
        "source": "FrequencyWords by Hermit Dave (OpenSubtitles 2018), CC BY-SA 4.0",
        "packs": packs,
    }
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
