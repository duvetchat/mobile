#!/usr/bin/env python3
"""Writes assets/licenses/android/libwebrtc.txt (#403): the notices of libwebrtc as io.github.webrtc-sdk:android builds
it, for the version the flutter_webrtc fork names, made from its sources without a checkout (gclient's is tens of GB):
for webrtc-sdk/webrtc at the commit webrtc-sdk/webrtc-build built that version from (its build/VERSION) and each part
the Android library builds in, the licence files WebRTC's own tools_webrtc/libs/generate_licenses.py names for it,
and the NOTICE and PATENTS beside the first of them, which that tool leaves out (webrtc-sdk's NOTICE credits the
Apache-2.0 code it took in), each fetched alone from the repository and revision webrtc's DEPS pins. Parts whose files
are the same text share one copy.

  tool/libwebrtc_notices.py [<version>] [--notice <NOTICE>]

<version> is the fork's by default (its android/build.gradle, through .dart_tool/package_config.json: flutter pub get
first). PARTS and LEFT_OUT were made for CHECKED, from the NOTICE webrtc-build's own build wrote for it with
generate_licenses.py (gn desc of every target it builds, build tools included), which its run's webrtc.android.tar.gz
artifact holds, and from what the shipped library and its classes.jar show. Another version takes that NOTICE as
--notice: a part it names that neither list has stops the script, as does a part they have that it doesn't name.
Then check LEFT_OUT's reasons against the new library, and set CHECKED.
"""
import ast
import base64
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CHECKED = '150.7871.04'

# What the Android library builds in, by generate_licenses.py's names: webrtc first, then as its NOTICE orders them.
PARTS = [
    'webrtc', 'abseil-cpp', 'boringssl', 'compiler-rt', 'cpu_features', 'dav1d', 'fft', 'fiat', 'g711', 'g722',
    'jni_zero', 'libaom', 'libc++', 'libc++abi', 'libsrtp', 'libunwind', 'libvpx', 'libyuv', 'llvm-libc', 'ooura',
    'opus', 'pffft', 'rnnoise', 'spl_sqrt_floor',
]

# What the NOTICE also names, and why none of it ships.
LEFT_OUT = {
    'android_sdk': 'the SDK the build compiles against',
    'ijar': 'a build tool, which makes header jars',
    'nasm': "a build tool, the x86 builds' assembler",
    'kotlin_stdlib': "classes.jar holds no Kotlin class, only org.webrtc's and org.jni_zero's",
    'libjpeg_turbo': 'none of its messages is in the library',
    'perfetto': 'none of its types (the library keeps their names: RTTI) or strings is in the library',
    'protobuf': 'the build turns it off (rtc_enable_protobuf=false), and none of its types is in the library',
    'zlib': "none of its messages is in the library (its 'zlib compression' is an object name of BoringSSL's)",
}

WEBRTC = 'https://github.com/webrtc-sdk/webrtc'
ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'assets/licenses/android/libwebrtc.txt'


def fetch(url):
    """The body at url, asking again a few times while the host is busy (gitiles answers 429 and 503 to bursts)."""
    for attempt in range(5):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'libwebrtc_notices'})) as answer:
                return answer.read()
        except urllib.error.HTTPError as error:
            if error.code != 429 and error.code < 500 or attempt == 4:
                raise
        time.sleep(2 ** attempt)


def file_at(repository, revision, path, missing_ok=False):
    """A file of a repository at a revision, GitHub's raw file or gitiles' base64 of it; None for one it hasn't."""
    if repository.startswith('https://github.com/'):
        owner_repo = repository[len('https://github.com/'):].removesuffix('.git')
        url = f'https://raw.githubusercontent.com/{owner_repo}/{revision}/{path}'
    elif '.googlesource.com/' in repository:
        url = f"{repository.removesuffix('.git')}/+/{revision}/{path}?format=TEXT"
    else:
        sys.exit(f'{repository}: neither GitHub nor gitiles')
    try:
        data = fetch(url)
    except urllib.error.HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        raise
    if '.googlesource.com/' in repository:
        data = base64.b64decode(data)
    return data.decode('utf-8').replace('\r\n', '\n').strip('\n')


def evaluate(node, variables):
    """A DEPS value: strings, joined with +, in dicts and lists, and gclient's Var() and Str(), never run as code."""
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Dict):
        return {evaluate(k, variables): evaluate(v, variables) for k, v in zip(node.keys, node.values)}
    if isinstance(node, ast.List):
        return [evaluate(e, variables) for e in node.elts]
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return evaluate(node.left, variables) + evaluate(node.right, variables)
    if isinstance(node, ast.Call) and getattr(node.func, 'id', None) in ('Var', 'Str') and len(node.args) == 1:
        value = evaluate(node.args[0], variables)
        return variables[value] if node.func.id == 'Var' else value
    sys.exit(f'DEPS has what this script does not read: {ast.dump(node)[:120]}')


def assignment(source, name):
    return next(n.value for n in ast.parse(source).body if isinstance(n, ast.Assign) and n.targets[0].id == name)


def fork_version():
    config = json.loads((ROOT / '.dart_tool/package_config.json').read_text())
    root = next(p['rootUri'] for p in config['packages'] if p['name'] == 'flutter_webrtc')
    gradle = Path(urllib.request.url2pathname(root.removeprefix('file://'))) / 'android/build.gradle'
    return re.search(r'io\.github\.webrtc-sdk:android:([0-9.]+)', gradle.read_text()).group(1)


def main(args):
    notice = None
    if '--notice' in args:
        at = args.index('--notice')
        notice = Path(args[at + 1]).read_text()
        args = args[:at] + args[at + 2:]
    version = args[0] if args else fork_version()
    if notice is not None:
        listed = set(re.findall(r'^# (\S+)$', notice, re.MULTILINE))
        ours = set(PARTS) | set(LEFT_OUT)
        if listed != ours:
            sys.exit(f'the NOTICE names {sorted(listed - ours)}, which PARTS and LEFT_OUT lack, '
                     f'and not {sorted(ours - listed)}, which they have')
    elif version != CHECKED:
        sys.exit(f"PARTS and LEFT_OUT are {CHECKED}'s: check them against {version} (--notice), then set CHECKED")

    build_version = fetch(f'https://raw.githubusercontent.com/webrtc-sdk/webrtc-build/m{version}/build/VERSION')
    build = dict(re.findall(r'^(\w+)=(\S+)$', build_version.decode(), re.MULTILINE))
    if build.get('WEBRTC_VERSION') != version:
        sys.exit(f"webrtc-build m{version} built {build.get('WEBRTC_VERSION')}")
    commit = build['WEBRTC_COMMIT']

    deps_source = file_at(WEBRTC, commit, 'DEPS')
    variables = evaluate(assignment(deps_source, 'vars'), {})
    deps = {}
    for path, value in evaluate(assignment(deps_source, 'deps'), variables).items():
        url = value.get('url') if isinstance(value, dict) else value
        if url:
            deps[path.removeprefix('src/')] = url.rsplit('@', 1)
    licences = ast.literal_eval(
        assignment(file_at(WEBRTC, commit, 'tools_webrtc/libs/generate_licenses.py'), 'LIB_TO_LICENSES_DICT'))

    texts = {}  # text: (its parts, where each of its files came from)
    for part in PARTS:
        named = licences[part]
        if not named:
            sys.exit(f'generate_licenses.py names no licence file for {part}')
        folder = named[0].rpartition('/')[0]
        beside = [f'{folder}/{name}'.lstrip('/') for name in ('NOTICE', 'PATENTS')]
        sources, text = [], []
        for file in named + [file for file in beside if file not in named]:
            # The deepest DEPS checkout that holds the file, else webrtc's own tree.
            holder = max((p for p in deps if file.startswith(p + '/')), key=len, default=None)
            repository, revision = deps[holder] if holder else (WEBRTC, commit)
            found = file_at(repository, revision, file[len(holder) + 1:] if holder else file, file not in named)
            if found is not None:
                text.append(found)
                sources.append(f'{file}: {repository} at {revision}')
        shared = texts.setdefault('\n\n'.join(text), ([], []))
        shared[0].append(part)
        shared[1].extend(sources)

    out = [f'libwebrtc {version}, as io.github.webrtc-sdk:android {version} builds it: webrtc-sdk/webrtc at {commit}, '
           f'and what it builds in, each part from the revision its DEPS pins (tool/libwebrtc_notices.py).']
    for text, (parts, sources) in texts.items():
        # A rule none of the texts has: LLVM's draw theirs with =.
        out += ['', '#' * 80, ', '.join(parts), *sources, '', text]
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open('w', encoding='utf-8', newline='\n') as file:
        file.write('\n'.join(out) + '\n')
    print(f'{OUTPUT.relative_to(ROOT)}: {len(PARTS)} parts in {len(texts)} notices, webrtc-sdk/webrtc at {commit}')


if __name__ == '__main__':
    main(sys.argv[1:])
