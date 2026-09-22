#!/usr/bin/env python3
"""Validate the repository's bilingual documentation, localization, and branch contract."""
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'arkit-3dgs-scanner'
errors = []


def check(condition, message):
    if not condition:
        errors.append(message)


def read_strings(path):
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def swift_string(source, offset):
    """Read a regular Swift literal, including balanced interpolation expressions."""
    assert source[offset] == '"'
    i = offset + 1
    pieces, arguments, part = [], 0, ''
    while i < len(source):
        if source[i] == '"':
            pieces.append(part)
            if arguments:
                pieces = [p.replace('%', '%%') for p in pieces]
            key = '%@'.join(pieces)
            # The project's UI literals use standard escaped quotes/newlines/backslashes.
            return i + 1, json.loads('"' + key + '"')
        if source.startswith('\\(', i):
            pieces.append(part)
            part = ''
            arguments += 1
            i += 2
            depth = 1
            while depth:
                if source[i] == '"':
                    i, _ = swift_string(source, i)
                    continue
                if source[i] == '(':
                    depth += 1
                elif source[i] == ')':
                    depth -= 1
                i += 1
            continue
        if source[i] == '\\':
            part += source[i:i + 2]
            i += 2
        else:
            part += source[i]
            i += 1
    raise ValueError(f'Unclosed Swift string at {offset}')


branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
check(not branch or branch == 'main' or
      re.fullmatch(r'(Feature|Bugfix|Enhance)/[a-z0-9]+(?:-[a-z0-9]+)*', branch),
      f'Invalid branch name: {branch}')

english = read_strings(APP / 'en.lproj/Localizable.strings')
chinese = read_strings(APP / 'zh-Hant.lproj/Localizable.strings')
check(english.keys() == chinese.keys(), 'Language resource key sets differ')
placeholder = re.compile(r'%(?:\d+\$)?[-+0 #]*(?:\d+)?(?:\.\d+)?(?:ll|l)?[@difus]|%%')
for key in english.keys() | chinese.keys():
    en, zh = english.get(key, ''), chinese.get(key, '')
    check(bool(en.strip()) and bool(zh.strip()), f'Empty translation: {key}')
    check(placeholder.findall(en) == placeholder.findall(zh) == placeholder.findall(key),
          f'Format placeholder mismatch: {key}')
    check(not re.search(r'[\u3400-\u9fff]', en), f'Untranslated English resource: {key}')

used = set()
for path in APP.rglob('*.swift'):
    source = path.read_text()
    for match in re.finditer(r'L10n\.text\(\s*(?=")', source):
        _, key = swift_string(source, match.end())
        used.add(key)
        check(key in english and key in chinese, f'Missing resource in {path.name}: {key}')
check(bool(used), 'No localized messages found')
for language in ['en', 'zh-Hant']:
    permissions = read_strings(APP / f'{language}.lproj/InfoPlist.strings')
    check(bool(permissions.get('NSCameraUsageDescription')), f'Missing camera permission: {language}')

markdown = list(ROOT.glob('*.md')) + list((ROOT / 'docs').glob('*.md'))
for path in markdown:
    zh = path.name.endswith('.zh-TW.md')
    counterpart = path.with_name(path.name.replace('.zh-TW.md', '.md') if zh else path.stem + '.zh-TW.md')
    check(counterpart.exists(), f'Missing document counterpart: {path.relative_to(ROOT)}')
    source = path.read_text()
    check(f']({counterpart.name})' in source, f'Missing language link: {path.name}')
    for target in re.findall(r'\]\(([^\s)]+)\)', source):
        if target.startswith(('https:', 'http:', '#', 'mailto:')):
            continue
        target = target.split('#', 1)[0]
        check((path.parent / target).exists(), f'Broken link in {path.name}: {target}')

if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS: {len(used)} localized keys, {len(english)} translations per language, '
      f'{len(markdown) // 2} document pairs; branch {branch or "detached HEAD"}')
