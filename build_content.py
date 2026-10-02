#!/usr/bin/env python3
import json, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.cache'
OPEN = CACHE / 'OpenJLPT'
KVG = CACHE / 'kanjivg'
DATA = ROOT / 'assets' / 'data'
STROKES = DATA / 'strokes'


def run(cmd):
    print('+', ' '.join(cmd))
    subprocess.run(cmd, check=True)


def clone(url, dest):
    if dest.exists():
        shutil.rmtree(dest)
    run(['git', 'clone', '--depth', '1', url, str(dest)])


def read_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def merge_openjlpt():
    vocab, kanji, grammar = [], [], []
    for level in ['n5', 'n4', 'n3', 'n2', 'n1']:
        vp = OPEN / 'data' / 'json' / 'vocab' / f'{level}.json'
        kp = OPEN / 'data' / 'json' / 'kanji' / f'{level}.json'
        gp = OPEN / 'data' / 'json' / 'grammar' / f'{level}.json'
        for e in read_json(vp):
            e = dict(e)
            e['level'] = level.upper()
            vocab.append(e)
        for e in read_json(kp):
            e = dict(e)
            e['level'] = level.upper()
            kanji.append(e)
        for e in read_json(gp):
            e = dict(e)
            e['level'] = level.upper()
            grammar.append(e)

    # Keep one stable copy of words/kanji that occur at multiple levels: easiest level wins.
    rank = {'N5': 0, 'N4': 1, 'N3': 2, 'N2': 3, 'N1': 4}
    vmap = {}
    for e in vocab:
        key = e.get('id') or f"{e.get('word')}|{e.get('reading')}"
        if key not in vmap or rank[e['level']] < rank[vmap[key]['level']]:
            vmap[key] = e
    kmap = {}
    for e in kanji:
        key = e.get('character')
        if key and (key not in kmap or rank[e['level']] < rank[kmap[key]['level']]):
            kmap[key] = e
    gmap = {e.get('id'): e for e in grammar if e.get('id')}

    DATA.mkdir(parents=True, exist_ok=True)
    (DATA / 'vocab.json').write_text(json.dumps(list(vmap.values()), ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    (DATA / 'kanji.json').write_text(json.dumps(list(kmap.values()), ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    (DATA / 'grammar.json').write_text(json.dumps(list(gmap.values()), ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    print('Content:', len(vmap), 'vocab,', len(kmap), 'kanji,', len(gmap), 'grammar')
    return set(kmap.keys())


def copy_strokes(chars):
    STROKES.mkdir(parents=True, exist_ok=True)
    source = KVG / 'kanji'
    copied = 0
    missing = []
    for ch in chars:
        if not ch or len(ch) != 1:
            continue
        code = f'{ord(ch):05x}'
        src = source / f'{code}.svg'
        dst = STROKES / f'{code}.svg'
        if src.exists():
            shutil.copy2(src, dst)
            copied += 1
        else:
            missing.append(ch)
    print('Stroke SVG:', copied, 'copied;', len(missing), 'missing')
    if missing:
        (DATA / 'strokes_missing.txt').write_text('\n'.join(missing), encoding='utf-8')


def main():
    clone('https://github.com/evanclan/OpenJLPT.git', OPEN)
    chars = merge_openjlpt()
    clone('https://github.com/KanjiVG/kanjivg.git', KVG)
    copy_strokes(chars)
    notice = DATA / 'NOTICE.txt'
    notice.write_text(
        'NihonGo Master Ultimate content sources:\n'
        '- OpenJLPT: CC BY-SA 4.0. OpenJLPT aggregates JMdict, KANJIDIC2, community JLPT level lists and Tatoeba.\n'
        '- KanjiVG: CC BY-SA 3.0, copyright Ulrich Apel and contributors.\n'
        'JLPT levels in OpenJLPT are community approximations; the JLPT does not publish current official vocabulary/kanji lists.\n',
        encoding='utf-8'
    )

if __name__ == '__main__':
    main()
