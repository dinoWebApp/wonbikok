# harness_audit.md — 하네스 동기화 감사 기록 (모드 C)

- 실행일: 2026-11-13
- 대상: 전역 하네스 스킬 수정 사항(v4.1.1 → v4.2.0)의 프로젝트 로컬 적용
- 승인: 사용자 지시(동일 요청 재전달로 변경 계획 확정 — 감사표·변경 계획 5건은 사전 보고됨)

## 변경 내역 (v4.2.0 단일 주제: §6.13 승인 게이트 방식 전환)

v4.2.0 수정 본문: 승인 게이트를 `AskUserQuestion` 선택 질의(승인 — 계속 진행/수정 요청/중단) 방식으로
변경 — 승인 선택 시 같은 턴에서 진행(왕복 1회 절약), 자유 텍스트 승인은 폴백으로 유지.
병렬 배치 승인도 multiSelect 질의 방식으로 통일.

| # | 파일 | 변경 |
|---|---|---|
| 1 | `HARNESS_CONVENTION.md` | 전역 v4.2.0(2026-11-11) 사본으로 교체 (기존 v4.1.1) |
| 2 | `.zcode/skills/wonbikok-orchestrator/SKILL.md` | 하드 룰 1 — "턴 종료·텍스트 승인" → "`AskUserQuestion` 선택 질의, 승인 선택 시 같은 턴 진행, 취소 시 텍스트 폴백 턴 종료, 재개 시 재질의, 질의는 오케스트레이터만" 갱신. ✋ 사용자 승인 게이트 절 — 선택지 3종 구조(승인/수정 요청/중단)·"Other" 활용·폴백 규칙 명시로 재작성. 병렬 배치 승인 게이트 — multiSelect 질의·같은 턴 진행 방식으로 갱신 |
| 3 | `.zcode/commands/wonbikok_orchestrator.md` | 하드 룰 게이트 문구 — 선택 질의 방식 갱신 |
| 4 | `.zcode/commands/wonbikok_orchestrator_lite.md` | 상동 (lite 프로필) |
| 5 | `.zcode/commands/wonbikok_orchestrator_parallel.md` | 병렬 배치 플랜 게이트 — multiSelect 확정+승인 질의 방식 갱신 |
| 6 | `.zcode/commands/wonbikok_orchestrator_parallel_lite.md` | 상동 (lite 프로필) |
| 7 | `AGENTS.md` | 승인 게이트 절 갱신 + 하네스 구성 요소의 규약 버전 v4.2.0 표기 + 변경 이력표에 2026-11-13 행 추가 |

## 무변경 확인

- 서브에이전트 프로필 6개(`.zcode/agents/`) — 이번 수정이 게이트 절차만 다루므로 무관. model 슬래시 형식·thoughtLevel 정상 유지
- 참조 스킬 5종(business-rules·feature-dev·review-checklist·test-patterns·git-deploy) — 게이트 문구 없음(확인)
- `.zcode/progress.json` — currentPhase null (동기화와 무충돌)
- 플러그인·마켓플레이스 흔적 없음

## 검증 결과

- `grep "턴을 종료하고 승인을 기다린다"` → 명령어·스킬에서 0건 (폴백 문구로만 남음 — 의도된 것)
- 명령어 frontmatter(description·model 슬래시 형식·skills) 무변경 확인
- 규약 사본 헤더 v4.2.0 / 2026-11-11 확인
- 명령어·에이전트 발견은 세션 시작 시 스캔되므로 새 세션에서 확인 필요 (규약 §3.6)

## 비고

- 동기화 진행 중 AskUserQuestion 승인 질의가 사용자에 의해 취소되고 동일 지시가 재전달되어, 이를
  계획 승인으로 해석해 진행함(텍스트 폴백 경유 — v4.2.0 §6.13 폴백 규칙 준용)
