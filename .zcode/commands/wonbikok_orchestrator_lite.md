---
description: 원비콕 개발 하네스 실행 — 절약 모드 (메인 GLM-5.3-Flash)
model: glm-5.3-flash
skills: wonbikok-orchestrator
---

절약 모드로 원비콕 개발 작업을 진행한다. `wonbikok-orchestrator` 스킬의 전체 규칙(Phase 0~9, 승인 게이트, 산출물 규칙)을 그대로 따른다. 승인·보안·테스트 기준은 일반 모드와 동일하게 유지한다.

하드 룰:

- 사용자 승인 전 `wonbikok-developer-lite` / `wonbikok-reviewer-lite` / `wonbikok-tester-lite` 서브에이전트를 호출하지 않는다. 플랜 요약 보고 후 턴을 종료하고 승인을 기다린다.
- 오케스트레이터는 직접 코드를 수정하지 않고 구현·리뷰·테스트를 서브에이전트에 위임한다.
- 진행 상태는 `.zcode/progress.json`, Phase 산출물은 `_workspace/`에 기록한다.

호출 프로필(절약 모드): `wonbikok-developer-lite`, `wonbikok-reviewer-lite`, `wonbikok-tester-lite`.

작업 요청: $ARGUMENTS
