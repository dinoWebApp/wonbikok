# AGENTS.md

이 파일은 omp 에이전트가 이 저장소에서 작업할 때 참고할 가이드입니다.

---

## 프로젝트 개요

- **원비콕(WonbiKok)**: 소규모 교습소·공부방 원장을 위한 "원비 납부 안내 → 입금 확인 → 현금영수증 자동 발행" 월간 마감 자동화 B2B SaaS. 1인 개발·운영.
- 핵심 가치: 원장의 매달 반나절 원비 마감을 15분 이내로. 학원 ERP가 아니라 원비 마감에만 집중하는 모바일 퍼스트 도구.
- 이용자: ① 원장(모바일 웹 앱, 메인) ② 학부모(비로그인 청구 링크 페이지) ③ 운영 관리자(1인, 데스크톱 콘솔).
- 외부 연동: **포트원**(정기결제 빌링키·현금영수증[외부 결제건=계좌이체]·본인인증) / **솔라피**(알림톡 + SMS/LMS 자동 대체발송).

시스템 구성:

```text
Browser (ERB + Turbo + Stimulus, 모바일 웹 우선)
   │
Rails 단일 앱 (Puma)
   ├── 원장 앱 영역        — 인증 세션 기반
   ├── 학부모 공개 페이지   — 예측 불가 토큰 URL, 로그인 없음
   ├── 관리자 콘솔         — 별도 주소·별도 인계(OTP), 데스크톱 우선
   │
   ├── Solid Queue (발송·발행·배치 비동기 — 월 1일/월말 피크 큐 처리)
   ├── Solid Cache / Solid Cable
   │
   └── 외부 API (Active Job + Service 객체로만 호출)
       ├── 포트원 REST v2  — 구독 결제 / 현금영수증 발급·취소 / 본인인증
       └── 솔라피 Messages v4 — 알림톡 / SMS·LMS 대체발송
```

## 기술 스택

- **Ruby 4.0.7** (mise/.ruby-version 고정), **Rails 8.1.4**
- DB: SQLite3 (>= 2.1) — 개발/운영 동일, db/schema.rb 커밋 필수
- 웹서버 Puma + Thruster, 배포 Kamal 2 (config/deploy.yml)
- 프론트: ERB + Hotwire (turbo-rails, stimulus-rails) + Tailwind CSS + Propshaft + importmap-rails (Node/npm 없음)
- 캐시/큐/실시간: solid_cache / solid_queue / solid_cable (DB 기반)
- 테스트: minitest + fixtures (+ capybara, selenium-webdriver 시스템 테스트)
- 정적 분석: RuboCop (rubocop-rails-omakase), Brakeman, bundler-audit
- 상세 규약: **ARCHITECTURE_CONVENTION.md (v1.1.0) 우선 참조**

## 빌드 및 실행 명령어

```bash
bin/setup                 # 의존성 설치 + DB 준비
bin/dev                   # 개발 서버 (Procfile.dev: rails + css/js watch)
bin/rails test            # 전체 테스트
bin/rails test test/models/invoice_test.rb   # 개별 파일
bin/rubocop               # 린트 (0 에러 게이트)
bin/rubocop -A            # 자동 수정
bin/brakeman              # 보안 정적 분석 (0 경고 게이트)
bin/bundler-audit         # 젬 취약점 점검
bin/ci                    # 로컬 CI (Rails 8.1)
bin/kamal deploy          # 프로덕션 배포 (git-deploy 스킬 절차 경유)
```

품질 게이트(커밋/병합/배포 조건): **RuboCop 0 에러 + Brakeman 0 경고 + 테스트 통과**.

## 데이터베이스

| 환경 | DB | 비고 |
|:---|:---|:---|
| development | SQLite (storage/) | 커밋 금지 |
| test | SQLite (in-memory/file) | fixtures 기반 |
| production | SQLite (Docker 볼륨) | Kamal 배포, 일 1회 백업 |

- 마이그레이션: `bin/rails generate migration ...`, db/migrate + schema.rb 커밋 필수.
- 핵심 개체(구현 순서 참고): Tenant(교습소) / User(원장·운영자) / Student / Guardian / Invoice / Payment / CashReceipt / MessageLog / Subscription / SupportTicket / AuditLog — PRD.md 14장 참조.

## 아키텍처

**ARCHITECTURE_CONVENTION.md가 존재하므로 해당 문서를 우선 참조한다.** 요약:

- MVC 단방향: Controller → (Form/Service, 필요 시만) → Model + Scope. 하위 계층은 상위를 모른다.
- Skinny Controller, Fat Model. 모델 비대 시 `app/services/{domain}/`, `app/forms/{domain}/` 로 분리.
- 서버가 HTML 렌더링(ERB). Turbo 규약: 폼 실패 `status: :unprocessable_entity`(422), 성공 리다이렉트 `status: :see_other`(303).
- 요청은 동기, 지연·외부 API 호출은 Active Job(Solid Queue)으로 분리.
- 도메인 분할 = 네임스페이스 단위 (예: `Admin::`, 청구/발행 도메인 모델 그룹).
- Stimulus는 UI 표현만. 클라이언트 상태 최소화.

## 핵심 비즈니스 규칙 (도메인별)

모든 규칙은 **PRD.md 22장 Rule ID 체계**로 관리한다. 코드 작성·리뷰·테스트 시 반드시 해당 Rule ID를 참조한다.

| 접두어 | 도메인 | 핵심 |
|:---|:---|:---|
| TEN | 테넌시·개인정보 | Tenant 단위 격리(서버측 검증), 주민번호 수집 금지, 식별정보 암호화·마스킹, 청구 스냅샷 불변 |
| INV | 청구 | 원생×당월 중복 생성 금지, 확정 후 수정 사유 기록, 취소청구 수납합계 제외 |
| PAY | 수납 | 완납 재처리 차단, 정정은 이력으로, 처리자·시간 기록 |
| CR | 현금영수증 | 발행 유일성(멱등), 자동발행=입금확인 트리거만, 공급자 최종확인 전 성공 표시 금지, 취소는 원본 연결 |
| MSG | 메시지 | 발송 유일성, 알림톡 실패 시 SMS 대체 필수, 재시도 무한반복 금지 |
| LNK | 학부모 공개 페이지 | 예측 불가 토큰, 타 청구·내부정보 노출 금지, 만료 링크 차단 |
| SUB | 구독 | 원생 상한 초과 등록 차단, 결제실패 3회 재시도 후 일시정지 |
| ADM | 관리자 | 파괴적 조치 사유 필수+감사 로그, 개인정보 기본 마스킹 |

데이터 무결성·멱등성 원칙의 상세는 PRD.md 14장·15장 참조.

## API · 라우팅 컨벤션

- JSON API 중심이 아닌 **ERB 풀스택 앱**. 라우팅은 `resources` 기반 RESTful 관례 준수(예외적 커스텀 라우트만).
- 원장 영역: 인증 세션 기반. 학부모 청구 페이지: 토큰 기반 공개 라우트(예: `/b/{token}`). 관리자: `Admin::` 네임스페이스 + 별도 레이아웃.
- 외부 API(포트원·솔라피) 호출과 웹훅 수신은 Service 객체 + 전용 컨트롤러에서만.

## 코딩 컨벤션

- **들여쓰기: 스페이스만 사용(탭 금지). Ruby·JavaScript·HTML·ERB 2칸, 그 외 언어 4칸** — RuboCop(omakase)이 단일 기준.
- 네이밍: Rails 표준 관례(파일 snake_case, 클래스 CamelCase, DB snake_case 복수형 테이블).
- 금지: 뷰에서 DB 직접 쿼리, 컨트롤러에 비즈니스 로직, 외부 API를 Job/Service 밖에서 직접 호출.
- 문구(안내 알림톡 등)는 코드에 하드코딩하지 않고 config/locales/ko.yml 또는 Template 원본 관리 체계로.

## 테스트 전략

- minitest + fixtures. 계층: 모델(검증·도메인) → 통합(컨트롤러·플로우) → 시스템(브라우저 E2E, 필요 시).
- 외부 API(포트원·솔라피)는 **테스트에서 실호출 금지** — 스텁/시리얼라이즈된 픽스처 응답으로 대체.
- Rule ID별 정상/경계/예외 시나리오 필수 (wonbikok-test-patterns 스킬 참조).

## 하네스: 원비콕 개발 자동화

**목표:** PRD 비즈니스 규칙과 AGENTS.md 아키텍처를 준수하는 코드의 구현·리뷰·테스트를 자동화한다.

**트리거:** 아래에 해당하는 모든 요청은 반드시 `wonbikok-orchestrator` 스킬을 사용하라:
- 기능 구현, 코드 수정, 리팩터링, 버그 수정
- 코드 리뷰, 테스트 작성, 디버깅
- 마이그레이션, 모델/컨트롤러/뷰 설계, 비즈니스 로직 검증
- 외부 연동(포트원·솔라피) 구현
- 위 작업의 후속 요청 (수정, 보완, 개선, 리팩터링, 재실행, 업데이트)

단, 순수한 문서 내용 확인 질문("~가 무슨 뜻이야?")은 직접 응답 가능.

**배포:** "git 배포", "커밋", "푸시", "배포", "push", "kamal 배포" 요청 시 `wonbikok-git-deploy` 스킬을 사용하라.

**하네스 구성 요소:** 에이전트는 `.omp/agents/` (wonbikok-developer/reviewer/tester), 스킬은 `.omp/skills/`, 진행 상태는 `.omp/progress.json`, 산출물은 `_workspace/`.

**변경 이력:**

| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
| 2026-10-20 | 초기 하네스 구성 | 전체 | 신규 구축 (HARNESS_CONVENTION v3.2.0 기준) |

## 구현 진행 상황 (로드맵)

PRD.md 18장 로드맵 기준. 현재 구현된 기능 없음(하네스 구축 단계).

| 단계 | 범위 | 상태 |
|:---|:---|:---|
| W1 | 온보딩·사업자 연동(F1), 원생 관리(F2) — 연습 모드 | ⬜ 미착수 |
| W2 | 월간 청구·납부 안내(F3), 솔라피 알림톡, 리마인더(F6) | ⬜ 미착수 |
| W3 | 입금 확인(F4), 현금영수증(F5) + 학부모 청구 링크(F9) | ⬜ 미착수 |
| W4 | 대시보드(F7), 구독·결제(F8), 관리자 핵심(A1·A2·A3·A5) | ⬜ 미착수 |

작업 재개 가이드: `.omp/progress.json`의 currentPhase 확인 → `awaiting_approval`이면 플랜(01_plan.md) 재요약 후 승인 대기 → 이외에는 해당 Phase부터 재개. 상세는 HARNESS_CONVENTION.md §8.2.
