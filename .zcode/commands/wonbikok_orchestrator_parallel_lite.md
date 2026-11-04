---
description: 원비콕 개발 하네스 실행 — 병렬 배치 절약 모드 (메인 GLM-5.3-Flash)
model: "account:zai-individual-coding-plan/GLM-5.3-Flash"
skills: wonbikok-orchestrator
---

병렬 배치 절약 모드로 원비콕 개발 작업을 진행한다. `wonbikok-orchestrator` 스킬의 전체 규칙(Phase 0~9, 승인 게이트, 산출물 규칙)을 따르되, **스킬의 "병렬 배치 파이프라인(HARNESS_CONVENTION §6.14)" 절이 일반 Phase 절차에 우선 적용**된다.

하드 룰:

- 사용자 승인 전 `wonbikok-developer-lite` / `wonbikok-reviewer-lite` / `wonbikok-tester-lite` 서브에이전트를 호출하지 않는다. 병렬 배치 플랜(태스크 분해·파일 소유권 표·병렬/통합 분류·동시성 상한)을 보고 후 턴을 종료하고 승인을 기다린다.
- 병렬 fan-out은 구현(Phase 3-P)과 테스트 작성(Phase 7-P)만. 문서 현행화(Phase 2)·통합(Phase 3-S)·게이트(Phase 4/7-S)·리뷰는 직렬 배치로 처리한다.
- 각 병렬 Developer 위임에는 소유권 화이트리스트(자기 태스크 대상 파일만)·자체 검증 스코프 제한(자기 파일 단위)·repo-wide 명령 금지(전체 테스트·마이그레이션 생성은 통합 단계에서만)를 포함한다.
- `.zcode/progress.json`은 오케스트레이터만 기입한다. 태스크별 산출물은 `_workspace/parallel/<task-id>/`에 분리 기록한다.

호출 프로필(절약 모드): `wonbikok-developer-lite`, `wonbikok-reviewer-lite`, `wonbikok-tester-lite`.

작업 요청: $ARGUMENTS
