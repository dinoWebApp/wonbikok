# harness_audit.md — 하네스 동기화 감사 기록 (모드 C)

- 실행일: 2026-11-24
- 대상: 전역 하네스 수정(HARNESS_CONVENTION v4.2.0 → v4.2.1)의 프로젝트 로컬 적용
- 승인: 사용자가 변경 계획 승인(AskUserQuestion 선택 질의). 오케스트레이터 없이 오케스트레이터 본인이 직접 수정(사용자 지시)

## 변경 원본 (전역, 2026-11-23 수정)

- v4.2.1: 일반 모드 Reviewer 모델을 GLM-5.3 → GLM-5.4로 상향(§1.4 모델 프로필 표·§9.2 6단계).
  메인·Developer·Tester와 절약 모드 프로필은 기존 유지.
- 전역 메타 스킬($harness) §3.3·§3.4 표 동기화. GLM-5.4 미제공 계정의 예외 처리 지침 신설.

## 감사 결과

| 항목 | 경로 | 상태 | 조치 |
|---|---|---|---|
| 규약 사본 | `HARNESS_CONVENTION.md` | 불완전 (v4.2.0, 전역과 6곳 상이) | v4.2.1 사본으로 교체 |
| 일반 Reviewer 모델 | `.zcode/agents/wonbikok-reviewer.md` | 불완전 (`GLM-5.3`) | `GLM-5.4`로 변경 |
| 규약 버전 표기·변경 이력 | `AGENTS.md` | 불완전 (v4.2.0) | v4.2.1 표기, 이력 행 추가 |
| 메인 모델(명령어 4종)·나머지 프로필 5개 | `.zcode/commands/`, `.zcode/agents/` | 정상 | 변경 없음 (이번 개정 범위 밖) |
| 오케스트레이터 스킬·승인 게이트 3곳·병렬 후보 블록 | `.zcode/skills/`, `AGENTS.md` | 정상 | 변경 없음 |
| 플러그인·OMP 흔적 | `.zcode/` | 없음 | 없음 |
| GLM-5.4 사용 가능 여부 | 계정 모델 목록 | 정상 (`low`·`high`·`max`) | 예외 처리 불필요 |

## 변경 사항

1. `HARNESS_CONVENTION.md` — 전역 v4.2.1 사본으로 교체(프로젝트 전용 예외 규칙은 없었음 — 기존 사본도 전역 v4.2.0과 동일).
2. `.zcode/agents/wonbikok-reviewer.md` — frontmatter `model`만 `GLM-5.3` → `GLM-5.4`. `thoughtLevel: high`와 본문은 무변경.
3. `AGENTS.md` — 하네스 구성 요소의 규약 버전 v4.2.0 → v4.2.1, 변경 이력표에 2026-11-24 행 추가.

## 검증 결과

- 규약 사본 체크섬: 전역과 일치(`da137afb96ba1ab9df20a570baa93ed2`).
- 프로필 6개 frontmatter YAML 파싱 통과, v4.2.1 §3.4 표와 전부 일치:
  developer GLM-5.3-Flash/high · reviewer GLM-5.4/high · tester GLM-5.3-Flash/high ·
  developer-lite Flash/low · reviewer-lite Flash/high · tester-lite Flash/low.
- 명령어 4종 메인 모델 무변경(일반·병렬 GLM-5.3, 절약·병렬 절약 GLM-5.3-Flash) — 규약대로.
- Reviewer를 GLM-5.3로 적은 잔존: 없음(AGENTS.md 126행의 "메인 GLM-5.3"은 메인 모델 표기라 정상).

## 미검증·후속

- Reviewer가 실제로 GLM-5.4로 구동되는지는 아직 실측하지 못함 — 다음 오케스트레이터 실행의 Phase 5(리뷰)에서
  모델 I/O 로그로 확인해 `_workspace/00_delegation_log.md`에 기록한다.
- 명령어·에이전트 발견은 세션 시작 시 스캔되므로 새 세션에서 적용 여부를 확인한다.

## 커밋 게이트 경위 (2026-11-24)

첫 시도에서 게이트 3종이 모두 실행되지 않았다. 변경 자체의 문제는 아니고 실행 환경 원인 두 가지였다.

1. **mise 기본 Ruby가 4.0.10으로 바뀜** — 이 디렉터리의 `.ruby-version`(4.0.7)이 신뢰되지 않아("No trusted config
   files") `bin/*`가 젬 없는 4.0.10으로 실행돼 `GemNotFound`. 일단 PATH에 4.0.7을 넣어 실행했다.
2. **`bin/brakeman`의 `--ensure-latest`** — brakeman 8.1.1 출시 이후 8.1.0에서는 검사 없이 exit 5로 종료한다
   (CI의 `bin/brakeman --no-pager`도 같은 영향). `bundle update brakeman`으로 8.1.1을 적용했다.
3. 8.1.1이 **Ruby 4.0.7의 치명적 RCE(CVE-2026-132825)** 경고 1건을 보고했다 → 사용자 지시로 프로젝트를 Ruby 4.0.10으로
   올렸다(`.ruby-version`·`Dockerfile`·`config/deploy.yml`·`AGENTS.md`·`bundle install`). 이후 PATH 조정 없이 게이트 통과.

최종 게이트(Ruby 4.0.10·brakeman 8.1.1): RuboCop 198파일 0 에러 · Brakeman 경고 0(exit 0) · 테스트 592 runs 0 실패.
