# -*- coding: utf-8 -*-
"""배치파일의 모델 데이터를 index.html 안에 직접 넣는다.

사용법 (저장소 루트에서):
    python tools/웹사이트_생성.py

결과물은 파일 1개(index.html)다.
서버도, 외부 JS 파일도 필요 없어서 그대로 배포하면 된다.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BAT = os.path.join(HERE, "멘사_IQ_오답예측기.bat")
INDEX = os.path.join(ROOT, "index.html")

src = open(BAT, "r", encoding="utf-8").read().splitlines()
sys.argv = [BAT]
ns = {"__name__": "export_model", "__file__": BAT}
exec(compile("\n".join(src[1:]), BAT, "exec"), ns)

BASE = ns["BASE"]
GAP = ns["GAP"]
EXTRA = ns["EXTRA"]
LOW_K = ns["LOW_K"]
CEIL_TEXT = ns["CEIL_TEXT"]
CEIL_MIN = ns["CEIL_MIN"]
N_ITEMS = ns["N_ITEMS"]
MISSING = ns["MISSING"]


def norm(value):
    """내부 MISSING 센티널을 JSON null 로 바꾼다."""
    if value is MISSING:
        return None
    return value


base_out = {}
for age in sorted(BASE):
    base_out[str(age)] = [norm(v) for v in BASE[age]]

data = {
    "N_ITEMS": N_ITEMS,
    "CEIL_TEXT": CEIL_TEXT,
    "CEIL_MIN": CEIL_MIN,
    "LOW_K": round(LOW_K, 6),
    "BASE": base_out,
    "GAP": [[a, w, norm(v)] for a, w, v in GAP],
    "EXTRA": [[a, w, norm(v)] for a, w, v in EXTRA],
}

js = "window.IQ_MODEL = " + json.dumps(data, ensure_ascii=False, indent=2) + ";"

with open(INDEX, "r", encoding="utf-8") as f:
    html = f.read()

pattern = re.compile(r"/\*__MODEL_DATA_START__\*/.*?/\*__MODEL_DATA_END__\*/", re.S)
if not pattern.search(html):
    raise SystemExit("index.html 안에 데이터 마커가 없습니다.")

new_block = "/*__MODEL_DATA_START__*/\n" + js + "\n/*__MODEL_DATA_END__*/"
html = pattern.sub(lambda m: new_block, html, count=1)

with open(INDEX, "w", encoding="utf-8") as f:
    f.write(html)

print("저장:", INDEX)
print("기준표:", len(base_out), "개 나이")
print("보정표:", len(data["GAP"]), "칸")
print("추가검증:", len(data["EXTRA"]), "칸")
print("저IQ 배율:", data["LOW_K"])
print("파일 크기:", os.path.getsize(INDEX), "bytes")
