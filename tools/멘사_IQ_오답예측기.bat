@echo off & chcp 65001 >nul & title 멘사 도형테스트 IQ-오답 역산 예측기 & python -x "%~f0" %* & pause & exit /b
# -*- coding: utf-8 -*-
"""
멘사 도형테스트(39문항) IQ -> 오답 개수 역산 예측기

[모델]
- 기준표: iq_matrix_70s_fast.csv (14개 나이 x 11개 오답 = 154칸)
- 보정표: iq_gap_validation_32.csv (기준표에 없는 중간 나이 39칸)
- 두 표의 모든 (나이, 오답) -> IQ 관측값을 앵커로 사용한다.
- 같은 오답 칸(w) 안에서 나이에 대해 선형 보간/외삽한다.
- '145이상'은 관측된 가장 이른 천장 나이를 경계로 판정하고,
  보간값이 144.5 이상이면 역시 '145이상'으로 처리한다.
- 따라서 기준표 154칸 + 보정표 39칸을 전부 재현한다.
"""

import csv
import math
import os
import sys

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

N_ITEMS = 39
CEIL_TEXT = "145이상"
CEIL_MIN = 144.5
MISSING = object()

# ==============================================================================
# 기준표 (iq_matrix_70s_fast.csv) 원본 값. None = '145이상'
# ==============================================================================
BASE_EMBEDDED = {
    15: [None, 144, 139, 136, 131, 129, 126, 122, 118, 114, 111],
    18: [None, 142, 137, 134, 129, 127, 124, 120, 116, 112, 109],
    21: [None, 139, 134, 131, 126, 124, 122, 118, 114, 110, 107],
    24: [None, 138, 134, 131, 126, 124, 121, 117, 113, 110, 107],
    28: [None, 140, 135, 132, 128, 126, 123, 119, 115, 111, 108],
    33: [None, 143, 138, 135, 130, 128, 125, 121, 117, 113, 110],
    38: [None, 144, 139, 136, 131, 129, 126, 122, 118, 114, 111],
    43: [None, None, 143, 140, 135, 133, 130, 126, 122, 118, 114],
    48: [None, None, None, None, 140, 138, 134, 130, 126, 122, 119],
    53: [None, None, None, None, None, 143, 139, 135, 131, 126, 123],
    58: [None, None, None, None, None, None, None, 140, 136, 131, 128],
    63: [None, None, None, None, None, None, None, 143, 139, 134, 131],
    68: [None, None, None, None, None, None, None, None, 140, 135, 132],
    73: [None, None, None, None, None, None, None, None, 142, 137, 133],
}

# ==============================================================================
# 보정표 (iq_gap_validation_32.csv) 원본 값. (나이, 오답 수, IQ 또는 None=145이상)
# ==============================================================================
GAP_EMBEDDED = [
    (22, 4, 125), (22, 1, 138), (23, 1, 138), (22, 2, 133),
    (23, 2, 133), (23, 3, 130), (23, 5, 124), (25, 1, 139),
    (25, 2, 134), (26, 2, 134), (26, 3, 132), (27, 2, 135),
    (25, 4, 126), (27, 3, 132), (27, 5, 125), (26, 5, 125),
    (30, 2, 136), (30, 4, 128), (35, 2, 138), (35, 3, 135),
    (35, 4, 131), (35, 6, 126), (40, 1, None), (40, 2, 140),
    (45, 2, None), (40, 4, 132), (45, 3, 142), (45, 5, 135),
    (50, 3, None), (50, 4, 142), (50, 6, 136), (55, 4, None),
    (55, 5, None), (65, 6, None), (60, 6, None), (60, 7, 142),
    (70, 7, None), (70, 8, 142), (65, 7, 144),
]

# ==============================================================================
# 추가 검증 (iq_extra_validation.csv) 원본 값.
# 사용자가 실제 사이트에서 직접 확인한 값이다.
#   - 16세 1개 = 143   : 실측이 없던 나이의 보간값이 맞았음
#   - 44세 2개 = 144   : 145이상 경계 판정이 맞았음
#   - 24세 15개 = 98   : 저IQ 외삽이 92로 틀렸음 -> 기울기 보정 근거
# ==============================================================================
EXTRA_EMBEDDED = [
    (16, 1, 143),
    (44, 2, 144),
    (24, 15, 98),
]

# 오답 11개 이상은 실측이 없는 저IQ 외삽 구간이다.
# 9->10 구간 기울기에 이 배율을 곱해서 사용한다. (1.00 = 기존, 보정 후 0.60)
LOW_IQ_MIN_W = 11
LOW_K_DEFAULT = 0.6


def script_dir():
    """배치파일이 있는 폴더 (python -x 로 실행해도 sys.argv[0] 이 배치파일 경로)."""
    try:
        return os.path.dirname(os.path.abspath(sys.argv[0]))
    except Exception:
        return os.getcwd()


def _candidate(name):
    for folder in (script_dir(), os.getcwd()):
        path = os.path.join(folder, name)
        if os.path.exists(path):
            return path
    return None


def _parse_iq_cell(text):
    c = str(text).strip()
    if (not c) or ("이상" in c) or (c in ("누락", "에러", "측정실패")):
        return None if "이상" in c else MISSING
    try:
        return int(float(c))
    except ValueError:
        return MISSING


def load_base():
    """기준표 CSV를 읽고, 없으면 내장 기준표를 쓴다."""
    path = _candidate("iq_matrix_70s_fast.csv")
    if not path:
        return dict(BASE_EMBEDDED), "내장 기준표"
    table = {}
    try:
        with open(path, "r", encoding="utf-8-sig", newline="") as f:
            rd = csv.reader(f)
            next(rd, None)
            for row in rd:
                if not row:
                    continue
                age = int(row[0].replace("세", "").strip())
                vals = [_parse_iq_cell(cell) for cell in row[1:]]
                if vals:
                    table[age] = vals
    except Exception:
        table = {}
    if table:
        return table, os.path.basename(path)
    return dict(BASE_EMBEDDED), "내장 기준표"


def load_gap():
    """보정표 CSV를 읽고, 없으면 내장 보정표를 쓴다."""
    path = _candidate("iq_gap_validation_32.csv")
    if not path:
        return list(GAP_EMBEDDED), "내장 보정표"
    rows = []
    try:
        with open(path, "r", encoding="utf-8-sig", newline="") as f:
            rd = csv.reader(f)
            next(rd, None)
            for row in rd:
                if len(row) < 3:
                    continue
                try:
                    age = int(str(row[0]).replace("세", "").strip())
                    wrong = int(str(row[1]).replace("개", "").strip())
                except ValueError:
                    continue
                iq_cell = row[3] if len(row) >= 4 else row[2]
                val = _parse_iq_cell(iq_cell)
                if val is not MISSING:
                    rows.append((age, wrong, val))
    except Exception:
        rows = []
    if rows:
        return rows, os.path.basename(path)
    return list(GAP_EMBEDDED), "내장 보정표"


def load_extra():
    """추가 검증 CSV를 읽고, 없으면 내장 추가 검증값을 쓴다."""
    path = _candidate("iq_extra_validation.csv")
    if not path:
        return list(EXTRA_EMBEDDED), "내장 추가검증"
    rows = []
    try:
        with open(path, "r", encoding="utf-8-sig", newline="") as f:
            rd = csv.reader(f)
            next(rd, None)
            for row in rd:
                if len(row) < 3:
                    continue
                try:
                    age = int(str(row[0]).replace("세", "").strip())
                    wrong = int(str(row[1]).replace("개", "").strip())
                except ValueError:
                    continue
                iq_cell = row[3] if len(row) >= 4 else row[2]
                val = _parse_iq_cell(iq_cell)
                if val is not MISSING:
                    rows.append((age, wrong, val))
    except Exception:
        rows = []
    if rows:
        return rows, os.path.basename(path)
    return list(EXTRA_EMBEDDED), "내장 추가검증"


BASE, BASE_SRC = load_base()
GAP, GAP_SRC = load_gap()
EXTRA, EXTRA_SRC = load_extra()

# 오답 칸(w)별 관측값: NUM[w] = {나이: IQ}, CEIL[w] = {나이: ...}
NUM = {}
CEIL = {}


def add_point(age, wrong, val):
    if val is MISSING:
        return
    NUM.get(wrong, {}).pop(age, None)
    CEIL.get(wrong, set()).discard(age)
    if val is None:
        CEIL.setdefault(wrong, set()).add(age)
    else:
        NUM.setdefault(wrong, {})[age] = int(val)


for _age, _row in BASE.items():
    for _w, _val in enumerate(_row):
        add_point(_age, _w, _val)
for _age, _w, _val in GAP:
    add_point(_age, _w, _val)
# 추가 검증 중 오답 10개 이하만 일반 앵커로 넣는다.
# 11개 이상은 저IQ 외삽 보정에만 사용한다 (나이 보간에 섞이면 안 됨).
for _age, _w, _val in EXTRA:
    if _w <= 10:
        add_point(_age, _w, _val)

MAX_W = max(list(NUM.keys()) + list(CEIL.keys()))
CEIL_AGE = {w: min(ages) for w, ages in CEIL.items() if ages}
MIN_AGE = min(BASE.keys())
MAX_AGE = max(BASE.keys())


def numeric_value(age, wrong):
    """같은 오답 칸 안에서 나이에 대해 선형 보간/외삽한 IQ."""
    pts = sorted(NUM.get(wrong, {}).items())
    if not pts:
        return None
    if len(pts) == 1:
        return float(pts[0][1])
    if age <= pts[0][0]:
        (a1, v1), (a2, v2) = pts[0], pts[1]
        return v1 + (v2 - v1) * (age - a1) / float(a2 - a1)
    if age >= pts[-1][0]:
        (a1, v1), (a2, v2) = pts[-2], pts[-1]
        return v2 + (v2 - v1) * (age - a2) / float(a2 - a1)
    for i in range(len(pts) - 1):
        a1, v1 = pts[i]
        a2, v2 = pts[i + 1]
        if a1 <= age <= a2:
            if a1 == a2:
                return float(v1)
            return v1 + (v2 - v1) * (age - a1) / float(a2 - a1)
    return float(pts[-1][1])


# 저IQ(오답 11개 이상) 외삽 배율.
# 실측 저IQ 값이 있으면 그 값에 맞도록 배율을 자동 계산한다.
LOWIQ = [(a, w, v) for (a, w, v) in EXTRA if w >= LOW_IQ_MIN_W and v is not None]


def calibrate_low_k():
    ks = []
    for age, w, iq in LOWIQ:
        v9 = numeric_value(age, MAX_W - 1)
        v10 = numeric_value(age, MAX_W)
        if v9 is None or v10 is None:
            continue
        denom = (v10 - v9) * (w - MAX_W)
        if denom == 0:
            continue
        ks.append((iq - v10) / denom)
    if not ks:
        return LOW_K_DEFAULT
    return sum(ks) / len(ks)


LOW_K = calibrate_low_k()


def iq_at(age, wrong):
    """(나이, 오답 수) -> '145이상' 또는 정수 IQ."""
    if wrong == 0:
        return CEIL_TEXT

    if wrong > MAX_W:
        # 9->10 구간의 기울기에 저IQ 보정 배율(LOW_K)을 곱해 외삽
        v9 = numeric_value(age, MAX_W - 1)
        v10 = numeric_value(age, MAX_W)
        if v9 is None or v10 is None:
            return CEIL_TEXT
        v = v10 + (v10 - v9) * LOW_K * (wrong - MAX_W)
    else:
        ceil_age = CEIL_AGE.get(wrong)
        if ceil_age is not None and age >= ceil_age:
            return CEIL_TEXT
        v = numeric_value(age, wrong)

    if v is None:
        return CEIL_TEXT
    if v >= CEIL_MIN:
        return CEIL_TEXT
    return int(math.floor(v + 0.5))


def parse_iq(text):
    """입력 문자열 -> None(145이상) 또는 정수 IQ."""
    s = str(text).strip().replace(" ", "")
    if not s:
        raise ValueError("빈 값")
    if "이상" in s or s.endswith("+"):
        return None
    v = int(float(s.replace("+", "")))
    return None if v >= 145 else v


def predict(age, text):
    """(나이, IQ 표기) -> 오답 개수 예측 결과."""
    target = parse_iq(text)

    if target is None:
        max_w = 0
        for w in range(MAX_W + 1):
            if iq_at(age, w) == CEIL_TEXT:
                max_w = w
            else:
                break
        return {
            "status": "ceiling",
            "wrong_min": 0,
            "wrong_max": max_w,
            "correct_min": N_ITEMS - max_w,
            "correct_max": N_ITEMS,
        }

    exact = []
    best_w, best_diff = 0, 10 ** 9
    for w in range(N_ITEMS):
        iq = iq_at(age, w)
        if iq == CEIL_TEXT:
            continue
        d = abs(iq - target)
        if d == 0:
            exact.append(w)
        if d < best_diff:
            best_diff, best_w = d, w

    if exact:
        return {
            "status": "exact" if len(exact) == 1 else "range",
            "wrong_min": exact[0],
            "wrong_max": exact[-1],
            "correct_min": N_ITEMS - exact[-1],
            "correct_max": N_ITEMS - exact[0],
        }
    return {
        "status": "approx",
        "wrong_min": best_w,
        "wrong_max": best_w,
        "correct_min": N_ITEMS - best_w,
        "correct_max": N_ITEMS - best_w,
        "diff": best_diff,
    }


def selftest_base():
    ok = total = 0
    for age, row in BASE.items():
        for w, val in enumerate(row):
            if val is MISSING:
                continue
            total += 1
            label = CEIL_TEXT if val is None else str(val)
            res = predict(age, label)
            if res["wrong_min"] <= w <= res["wrong_max"]:
                ok += 1
    return ok, total


def selftest_gap():
    ok = total = 0
    for age, w, val in GAP:
        if val is MISSING:
            continue
        total += 1
        label = CEIL_TEXT if val is None else str(val)
        res = predict(age, label)
        fwd = iq_at(age, w)
        good = (res["wrong_min"] <= w <= res["wrong_max"]) and (
            (fwd == CEIL_TEXT and val is None) or (fwd == val))
        if good:
            ok += 1
    return ok, total


def selftest_extra():
    ok = total = 0
    for age, w, val in EXTRA:
        if val is MISSING:
            continue
        total += 1
        label = CEIL_TEXT if val is None else str(val)
        res = predict(age, label)
        fwd = iq_at(age, w)
        good = (res["wrong_min"] <= w <= res["wrong_max"]) and (
            (fwd == CEIL_TEXT and val is None) or (fwd == val))
        if good:
            ok += 1
    return ok, total


def print_banner():
    ok1, total1 = selftest_base()
    ok2, total2 = selftest_gap()
    ok3, total3 = selftest_extra()
    print("=" * 64)
    print("      멘사 도형테스트 IQ -> 오답 수 역산 예측기")
    print(f"      - 기준표: {BASE_SRC}  ({total1}칸)")
    print(f"      - 보정표: {GAP_SRC}  ({total2}칸)")
    print(f"      - 추가검증: {EXTRA_SRC}  ({total3}칸)")
    print(f"      - 검증: 기준 {ok1}/{total1}, 보정 {ok2}/{total2}, 추가 {ok3}/{total3}")
    print(f"      - 저IQ 외삽 배율: {LOW_K:.2f} (실측 {len(LOWIQ)}칸 기준)")
    print("      - 모델: 오답 칸별 관측값 보간 (기준표 + 보정표 + 추가검증)")
    print("      (종료하려면 언제든 'q' 또는 '종료'를 입력하세요)")
    print("=" * 64)


def print_age_table(age):
    """해당 나이의 오답별 IQ 표를 출력한다."""
    print(f"\n  [참고] 만 {age}세 오답별 IQ")
    print("  " + "-" * 34)
    for w in range(MAX_W + 1):
        print(f"   {w:2d}개 오답 : {iq_at(age, w)}")
    print("  " + "-" * 34)
    print("  [저IQ 구간 — 실측 없음, 외삽]")
    for w in range(MAX_W + 1, 21):
        print(f"   {w:2d}개 오답 : {iq_at(age, w)}")
    print("  " + "-" * 34)


def show_result(age, iq_text, res):
    print("\n" + "─" * 52)
    print(f"  [분석 결과] 만 {age}세  /  표기 IQ: {iq_text}")
    print("─" * 52)

    if res["status"] == "ceiling":
        wmin, wmax = res["wrong_min"], res["wrong_max"]
        if wmax == 0:
            print("  ★ 틀린 개수 : 0개 (All Correct, 만점)")
            print("  ★ 맞은 개수 : 39개 / 39개 (정답률 100.0%)")
            print(f"  ℹ️  해설    : 만 {age}세는 1개도 틀리지 않아야 '145이상'이 나옵니다.")
        else:
            print(f"  ★ 틀린 개수 : {wmin} ~ {wmax}개 허용")
            print(f"  ★ 맞은 개수 : {res['correct_min']} ~ {res['correct_max']}개")
            print(f"  ℹ️  해설    : 만 {age}세는 최대 {wmax}개까지 틀려도 '145이상'이 나옵니다.")
        return

    wmin, wmax = res["wrong_min"], res["wrong_max"]
    if wmin == wmax:
        w = wmin
        acc = round((N_ITEMS - w) / float(N_ITEMS) * 100, 1)
        print(f"  ★ 틀린 개수 : {w}개")
        print(f"  ★ 맞은 개수 : {N_ITEMS - w}개 / {N_ITEMS}개 (정답률 {acc}%)")
    else:
        print(f"  ★ 틀린 개수 : {wmin} ~ {wmax}개")
        print(f"  ★ 맞은 개수 : {res['correct_min']} ~ {res['correct_max']}개")

    if res["status"] == "approx":
        print("  ℹ️  해설    : 표에 정확히 일치하는 칸이 없어 가장 가까운 값입니다.")
        print(f"                (예상 IQ 차이 {res['diff']}점)")
    elif res["status"] == "range":
        print(f"  ℹ️  해설    : 반올림 때문에 {wmin}~{wmax}개가 같은 IQ로 표시됩니다.")
    else:
        print(f"  ℹ️  해설    : 만 {age}세 표에서 {iq_text}는 {wmin}개 오답 칸과 정확히 일치합니다.")

    print("─" * 52)
    print_age_table(age)


def main():
    print_banner()

    while True:
        try:
            print()
            age_input = input("▶ 나이를 입력하세요: ").strip()
            if age_input.lower() in ("q", "exit", "quit", "종료"):
                print("\n프로그램을 종료합니다. 이용해 주셔서 감사합니다!")
                break

            if not age_input.isdigit():
                print("[!] 나이는 숫자로 입력해 주세요.")
                continue

            age = int(age_input)
            if age < 1 or age > 120:
                print("[!] 나이는 1~120 사이로 입력해 주세요.")
                continue
            if age < MIN_AGE or age > MAX_AGE:
                print(f"    (참고: 기준표 실측 범위는 {MIN_AGE}~{MAX_AGE}세입니다. "
                      f"이 나이는 범위 밖 외삽값입니다.)")

            iq_input = input("▶ 사이트에서 나온 IQ를 입력하세요: ").strip()
            if iq_input.lower() in ("q", "exit", "quit", "종료"):
                print("\n프로그램을 종료합니다. 이용해 주셔서 감사합니다!")
                break
            if iq_input.lower() in ("표", "table", "t"):
                print_age_table(age)
                iq_input = input("▶ 사이트에서 나온 IQ를 입력하세요: ").strip()
                if iq_input.lower() in ("q", "exit", "quit", "종료"):
                    print("\n프로그램을 종료합니다. 이용해 주셔서 감사합니다!")
                    break

            res = predict(age, iq_input)
            show_result(age, iq_input, res)

        except ValueError:
            print("[!] IQ 형식을 확인해 주세요.")
        except Exception as e:
            print(f"[!] 오류 발생: {e}")


if __name__ == "__main__":
    main()
