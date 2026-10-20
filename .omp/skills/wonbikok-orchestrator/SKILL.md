---
name: wonbikok-orchestrator
description: 원비콕 개발 오케스트레이터. 신규 기능 구현, 코드 수정, 리팩터링, 버그 수정, 테스트 작성, 코드 리뷰, 디버깅 등 원비콕 프로젝트의 모든 개발 작업을 조율한다. 원비콕 관련 개발 요청, 기능 구현, 마이그레이션, 모델/컨트롤러/뷰 작업, 포트원·솔라피 연동, 비즈니스 로직 검증 요청 시 사용한다. 후속 작업(수정, 보완, 개선, 리팩터링, 재실행, 업데이트)도 처리한다.
---

# 원비콕 개발 오케스트레이터

## 이 스킬의 목적

원비콕(Rails 8.1 원비 마감 자동화 SaaS) 개발 요청을 Phase 0~9 파이프라인으로 통제한다. 오케스트레이터는 **절대 직접 코드를 수정하지 않는다** — 구현은 Developer, 검증은 Reviewer, 테스트는 Tester 에이전트에게 위임한다.

## 하드 룰 (최우선)

1. **사용자 승인 게이트 (§6.13)**: Phase 1 플랜을 요약 보고한 뒤 **턴을 종료하고 승인을 기다린다. 승인 전 어떤 에이전트도 스폰하지 않는다.** 승인 응답 후에는 재승인 없이 끝까지 자동 진행한다. `awaiting_approval` 상태에서 재개 시에는 플랜 재요약 후 승인 대기만 한다.
2. **직접 구현 금지**: 코드 수정은 모두 Developer 위임. 오케스트레이터는 통제·기계적 검증(Phase 4/8)·보고만.
3. **문서 선행**: Phase 2에서 PRD.md/AGENTS.md 현행화를 구현보다 먼저. "수정 사항 없음" 불허(최소 진행 상황 표 갱신).
4. **일회성 스폰**: 작업마다 task tool로 신규 스폰. 완료 에이전트 재소환 금지, 결과 수신 후 즉시 등록 해제 시도(`hub cancel`).
5. **경로 불변**: `.omp/progress.json`, `_workspace/` 위치 변경 금지.
6. **todo 동기화**: 에이전트 결과 수신 직후 첫 도구 호출 = 해당 todo done. progress.json 갱신 시 세트 갱신.

## 에이전트 호출 (task tool 단일 문법)

```json
{ "tasks": [{ "agent": "wonbikok-developer", "task": "PRD F2 원생 관리: 마이그레이션~컨트롤러 구현. Rule ID INV-001, TEN-001 준수. 산출물 _workspace/03_implementation.md 작성." }] }
```

```json
{ "tasks": [{ "agent": "wonbikok-reviewer", "task": "_workspace/03_implementation.md 대상 리뷰. 중점: CR-001 멱등성, TEN-001 격리. 결과 _workspace/05_review.md 작성." }] }
```

```json
{ "tasks": [{ "agent": "wonbikok-tester", "task": "Rule ID INV-001/PAY-001 시나리오 테스트 작성·실행. 외부 API 스텁 필수. 결과 _workspace/07_test_report.md 작성." }] }
```

## Phase 0: 컨텍스트 확인 (오케스트레이터)

1. `.omp/progress.json` 확인 — `currentPhase` 있으면 resume, `awaiting_approval`이면 플랜 재보고 후 승인 대기.
2. `_workspace/` 존재하면 → 직전 작업 산출물 파악. 새 작업이면 `_workspace_prev/`로 이동 후 시작.
3. `git status --short` — 소스에 미커밋 변경 시 사용자 확인(커밋/포함/stash).
4. PRD.md에서 관련 기능(F1~F9, A0~A9)·Rule ID 식별.
5. **작업 규모 판별**:

| 규모 | 판별 기준 | Phase 진행 |
|:---|:---|:---|
| **Full** | 새 도메인/엔티티, 새 라우트+액션, 비즈니스 로직 포함, 마이그레이션, 3파일+ 변경 | 0→1→✋→2→3→4→5→6?→7→8→9 |
| **Standard** | 기존 로직 수정, 1~2파일 기능 변경, 로직 버그 수정 | 1→✋→3→5→7 (2·4·8 생략 가능) |
| **Fast** | 오타·문구·포맷·주석·설정값, 테스트만 추가 | 1(간이)→✋→3→7 |

승인 게이트는 모든 규모 공통, 생략 불가.

## Phase 1: 요구사항 분석 (오케스트레이터)

PRD에서 관련 섹션·Rule ID·대상 파일 목록·모호점을 식별해 `_workspace/01_plan.md` 작성. 필수 항목: 작업 범위, 대상 파일, Rule ID 목록, PRD/AGENTS.md 수정 필요 항목, 에이전트 스폰 계획.

## ✋ 사용자 승인 게이트

`progress.json` → `"currentPhase": "awaiting_approval"` 갱신 → 플랜 요약 보고(pipelineType, Phase 순서, 각 에이전트 지시 요약, 변경 예상 파일, 리스크) → "플랜을 승인하시겠습니까?" 출력 후 **턴 종료**. 승인 시 이후 Phase 자동 진행.

## Phase 2: 문서 현행화 (오케스트레이터) — Full 필수

PRD.md(기능 명세·Rule ID·에러·데이터 모델)와 AGENTS.md(진행 상황 표)를 구현 전에 갱신. 버전·수정일 갱신. `_workspace/02_prd_update.md`에 변경 섹션 기록.

## Phase 3: 구현 (Developer 스폰)

task tool로 wonbikok-developer 신규 스폰. 지시에 PRD 섹션·Rule ID·출력 파일 명시. 산출물: 소스 + `_workspace/03_implementation.md`.

## Phase 4: 코드 정리 (오케스트레이터 직접)

기계적 검증 — 메인+테스트 전체 대상:

```bash
bin/rubocop                      # 0 에러 (필요시 -A 후 재확인)
bin/brakeman                     # 0 경고
bin/rails test                   # 컴파일/로딩 검증 겸용
```

실패 시 Developer 수정 스폰(재스폰, 이력은 _workspace 경유).

## Phase 5: 코드 리뷰 (Reviewer 스폰)

task tool로 wonbikok-reviewer 신규 스폰. 산출물: `_workspace/05_review.md`.
- `APPROVED` → Phase 7
- `CRITICAL/WARNING` → Phase 6 수정 후 Phase 7
- `BLOCKER` → Phase 6 수정 후 Phase 5 재리뷰 (5→6→5 루프 최대 2회, 초과 시 사용자 중재)

## Phase 6: 수정 (Developer 재스폰)

Reviewer 지적 사항만 최소 수정. `_workspace/05_review.md` 전달.

## Phase 7: 테스트 (Tester 스폰)

task tool로 wonbikok-tester 신규 스폰. 산출물: `_workspace/07_test_report.md`.
- 전부 통과 → Phase 8
- 실패(코드 버그) → Phase 6
- 실패(테스트 오류) → Tester 재스폰

## Phase 8: 실행 검증 (오케스트레이터 직접)

`bin/dev` 백그라운드 구동 → 부트 로그 확인(Puma/"Listening"/Rails 부트 완료) → 오류 키워드 점검 → WARN 분류([허용]/[수정 필요]/[주의], 수정 필요 시 Phase 4 회귀) → 종료. `_workspace/08_run_report.md` 기록.

## Phase 9: 완료 보고 (오케스트레이터)

1. 최종 보고: 변경 파일, 리뷰 결과, 테스트 결과, 실행 검증, 잔여 위험.
2. AGENTS.md 구현 진행 상황 표 갱신.
3. `.omp/progress.json` 리셋(`currentPhase: null`).
4. Git 커밋은 `wonbikok-git-deploy` 스킬 절차(품질 게이트 + 사용자 확인)로 수행함을 안내.

## 데이터 흐름

Phase 간 데이터는 `_workspace/` 파일(01→03→05→07→08)로 전달. 에이전트 컨텍스트는 전달하지 않는다(일회성 스폰). 진행 중 협업만 Agent Hub 허용.

## 에러 핸들링

| 상황 | 대응 |
|:---|:---|
| 에이전트 실패 | 1회 재시도 → 재실패 시 해당 Phase 건너뛰고 완료 보고에 누락 명시 |
| 규칙 충돌·명세 모호 | PRD 원문 인용, 해석 불가 시 사용자 질의 |
| 빌드/테스트 실패 | 로그 수집 → 오류 기반 Developer 수정 스폰 |
| 리뷰 루프 2회 초과 | 사용자에게 상황 보고, 루트 원인 분석 후 재결정 |
