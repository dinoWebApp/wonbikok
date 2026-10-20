@../AGENTS.md

# omp 런타임 보강

위 import로 루트 AGENTS.md(단일 소스)를 로드한다. 아래는 omp 런타임 전용 보강 사항이다.

## 에이전트

- 전문 에이전트 위치: `.omp/agents/` — `wonbikok-developer`(구현, @developer 롤), `wonbikok-reviewer`(리뷰, @reviewer 롤), `wonbikok-tester`(테스트, @developer 롤).
- 에이전트 스폰은 오케스트레이터가 task tool로만 수행한다:

```json
{ "tasks": [{ "agent": "wonbikok-developer", "task": "구현 지시..." }] }
```

- 완료된 에이전트 재소환 금지(일회성 스폰 원칙, HARNESS_CONVENTION §4.6). 후속 작업은 `_workspace/` 산출물을 전달해 신규 스폰한다.

## 스킬

- 위치: `.omp/skills/` — `wonbikok-orchestrator`(개발 요청 강제 라우팅), `wonbikok-git-deploy`(배포), 참조 스킬 4종(business-rules, feature-dev, review-checklist, test-patterns).
- 모든 개발 작업(구현·수정·리뷰·테스트·디버깅)은 **`/skill:wonbikok-orchestrator`** 로 진행한다. 강제 호출: `/skill:wonbikok-orchestrator {요청}`.

## 진행 상태·산출물

- Phase 진행 상태: `.omp/progress.json` (Git 관리, 경로 불변).
- Phase 산출물: `_workspace/{NN}_{description}.md` (Git 관리, 경로 불변).
- 스티키 강제 규칙: `.omp/RULES.md` — 컨텍스트 압축 후에도 유지된다.

## 설정

- modelRoles는 전역 `~/.omp/agent/config.yml`에서 단일 관리한다. **프로젝트 `.omp/config.yml`은 생성하지 않는다.**
