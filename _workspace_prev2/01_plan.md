# 01_plan.md — 전체 퍼블리싱 재구성 (uibowl 레퍼런스 2차)

- 작성일: 2026-11-04
- 모드: 절약 (`/wonbikok_orchestrator_lite`) — lite 프로필 위임
- 파이프라인: Full (0→1→✋→2→3→4→5→6?→7→8→9), 직렬 단일 작업 (병렬 배치 부적합 —
  `tailwind.config.js`·`application.css` 공통 클래스·`shared/` 파셜이 전 영역 공유 파일이므로)

## 1. 요구사항

사용자: "현재 전체 퍼블리싱이 마음에 들지 않습니다. uibowl mcp를 사용하여 전체 퍼블리싱을 재구성해주세요."

- 직전 작업(2026-11-04 완료, `_workspace_prev/_workspace/`)에서 적용한 "토스풍 화이트+청색
  미니멀" 스타일이 마음에 들지 않다는 것. 동일한 절제 원칙의 마이너 보정이 아니라
  **비주얼 방향의 전면 교체**가 요구 사항.
- 재구성 범위: "전체" — 랜딩페이지 10섹션 + 원장 앱 전체(대시보드·원생·청구·리마인더·
  온보딩·로그인·가입) + 공통 레이아웃·공통 컴포넌트.
- 승인 게이트에서 방향 확정 전환 허용: 아래 기본안(웜 오렌지)에 대한 사용자 변경 요청이
  있으면 토큰표만 교체하여 동일 파이프라인 진행.

## 2. uibowl 레퍼런스 (2026-11-04 2차 조사, 오케스트레이터 직접 수행)

### 채택 방향: 웜 오렌지 에디토리얼 (기본안)

| 참고 | 화면 | 채택 포인트 |
|---|---|---|
| 클래스101 (교육&도서, MAU 58만) | 검색·마이페이지·주문내역 | 화이트 바탕 + 웜 오렌지 주색(로고 컬러 계열), 블랙 강조 배너 + 오렌지 CTA, 텍스트 링크 오렌지. 교육 서비스 특유의 친근하고 따뜻한 톤 |
| 뱅크샐러드 (금융) | 온보딩·검색·게이미피케이션 | (보조 참고) 강한 대비의 큰 타이포, 컬러 일러스트 카드의 표현력. 다크 테마 자체는 40~60대 타깃 가독성 리스크로 미채택 |
| 폰코 (PC 랜딩) | 랜딩/다운로드 | (보조 참고) 히어로의 임팩트 있는 풀배경 컬러 사용 — 랜딩 히어로에 컬러 배경 적용 근거 |
| MS Clarity (PC 랜딩) | 랜딩/소개 | (보조 참고) 제품 화면 목업을 히어로 우측에 크게 배치하는 B2B SaaS 구조 — 기존 10섹션 IA 유지 근거 |

- 적용 원칙은 PRD 16.0을 준용하되 "정보 우선순위·레이아웃 구조" 차용을 유지하고,
  색채 체계만 청색→웜 오렌지로 전면 교체. 기능·문구·데이터 바인딩은 불변.
- 링크: https://uibowl.io/name/클래스%20101 ,
  https://uibowl.io/name/뱅크샐러드 ,
  https://uibowl.io/website/폰코?patterns=랜딩페이지 ,
  https://uibowl.io/website/마이크로소프트%20클래리티%20(Microsoft%20Clarity)?patterns=랜딩페이지

### 승인 시 변경 가능한 대안

- B안: 프리미엄 다크+그린 (뱅크샐러드 온보딩풍 — 딥 네이비/블랙 + 브랜드 그린)
- C안: 청색 유지 + 표현력 업그레이드 (색 교체 없이 카드 밀도·타이포·섀도 강화)

## 3. 디자인 토큰 변경안 (tailwind.config.js)

| 토큰 | 현행 | 변경 | 비고 |
|---|---|---|---|
| canvas | #F7F9FC (쿨 블루톤) | #FAF8F5 (웜 아이보리톤) | 앱·랜딩 공통 배경 |
| surface | #FFFFFF | #FFFFFF 유지 | |
| ink | #191F28 | #1D1A16 (웜톤 잉크) | 대비 유지 |
| muted | #667085 | #6B655D (웜톤 뮤트) | |
| line | #E4E7EC | #E8E2D9 (웜톤 경계선) | |
| brand.500/600/700 | #3478F6/#2563EB/#1D4ED8 (청색) | #F97316/#EA580C/#C2410C (웜 오렌지) | 600은 흰 글자 AA 대비 확보 |
| brand.50/100/200 | #EEF4FF/#DBE7FE/#BDD3FD | #FFF4ED/#FFE8D9/#FDDCB5 | 배지·연한 배경 |
| info | 청색 공용 | 오렌지 계열 공용(brand와 동일 스케일) | |
| success/warning/danger | 현행 유지 | 현행 유지 | 도메인 상태 의미 보존. 단 brand(오렌지)↔warning(앰버) 시각 혼동 리스크 → 배지는 "배경+테두리+아이콘" 조합으로 구분, Reviewer 검증 항목 |
| fontFamily | Pretendard 유지 | 유지 | |

공통 컴포넌트 클래스(app/assets/tailwind/application.css): `.btn-*`, `.field-input` 등은
brand 토큰 참조이므로 자동 반영. 추가로 카드/섹션 표현력 클래스(rounded-2xl·소프트 섀도·
섹션 대비)를 검토·보강.

## 4. 대상 파일 (재구성 범위)

- `tailwind.config.js` — 디자인 토큰 전면 교체
- `app/assets/tailwind/application.css` — 공통 컴포넌트 클래스 보강
- `app/views/layouts/` — application.html.erb, landing.html.erb (헤더·하단탭·푸터 톤)
- `app/views/shared/` — badge/button/card/empty_state/flash/form_field/page_header/stepper (8 파셜)
- `app/views/landing/` — show + 10 파셜 (hero/problems/solution/features/demo/social_proof/plan_card/pricing/regulation/faq/final_cta/beta_form)
- `app/views/dashboard/show.html.erb`
- `app/views/students/` — index/show/new/edit/_form/import_new/import_result (7)
- `app/views/invoices/` — index/edit/cancel/results (4)
- `app/views/reminders/` — index/settings/preview/history (4)
- `app/views/onboarding/` — step2~step5 (4)
- `app/views/registrations/new.html.erb`, `app/views/sessions/new.html.erb`
- `app/views/beta_applications/` — new/_form/done (3)
- 총 약 45개 뷰 파일 + 2 설정 파일

**불변 원칙**: 라우트·컨트롤러·모델·Job·로직·i18n 문구 키 변경 금지. 뷰 마크업·클래스·
CSS만 변경. 기존 데이터 바인딩·Turbo/Stimulus 훅(data-* 속성) 보존 필수.
a11y(44px 터치 영역, 대비 AA, aria 속성)는 기존 수준 유지·개선.

## 5. Rule ID / PRD 근거

- 퍼블리싱 변경이므로 비즈니스 로직 Rule의 직접 구현은 없음. 다만 뷰 표시 관련:
  - **TEN-003 계열**: 표시용 마스킹 유지 (뷰에서 마스킹 풀지 않기)
  - **INV/PAY 상태 표시**: 상태 배지(success/warning/danger)의 도메인 의미 유지
- PRD 13장(랜딩, 섹션 IA·문구 유지) / 16장(퍼블리싱 — 16.1 브랜드 컬러 재정의)
- 접근성: PRD 16.1 (터치 44px 이상, 40~60대 가독성)

## 6. Phase 2 문서 현행화 (Full 필수)

- `PRD.md` 16.1: 브랜드 주색 #3478F6(청색) → 웜 오렌지(#EA580C) 재정의, 색채 규율 문구 갱신,
  16.3 레퍼런스에 uibowl 2차 조사 결과 추가. 13장은 IA·문구 불변 확인(수정 없음이면 기록만).
- `AGENTS.md`: Phase 9에서 진행 상황 표 갱신 (Phase 2에서는 사전 메모만).
- `_workspace/02_prd_update.md`에 변경 섹션 기록.

## 7. 위임 계획 (절약 모드)

| Phase | 프로필 | 작업 |
|---|---|---|
| 3 | wonbikok-developer-lite 1개 | §3~4 전 범위 구현. 단일 위임(공유 파일 중심). 산출물 `03_implementation.md` |
| 4 | (오케스트레이터 직접) | bin/rubocop + bin/brakeman + bin/rails test |
| 5 | wonbikok-reviewer-lite 1개 | 변경 diff 리뷰. 산출물 `05_review.md` |
| 6 | wonbikok-developer-lite 1개 | 리뷰 지적 수정 (지적 시에만) |
| 7 | wonbikok-tester-lite 1개 | 전체 테스트 회귀 + 뷰 셀렉터 의존 테스트 수정. 산출물 `07_test_report.md` |
| 8 | (오케스트레이터 직접) | 서버 기동 실행 검증 → `08_run_report.md` |

각 스폰 직후 위임 실측(hard rule 9) → `00_delegation_log.md` 기록.

## 8. 리스크

1. **brand(오렌지)↔warning(앰버) 혼동** — 납부 예정(앰버) 배지와 CTA(오렌지)의 시각 구분.
   → 배지 구성(배경+테두리) 차별화 + 리뷰 검증 항목 명시.
2. **테스트 셀렉터 의존** — CSS 클래스 문자열을 assert하는 기존 테스트 존재 가능.
   → Phase 7에서 전체 회귀 + 필요 시 테스트 수정.
3. **40~60대 대비(AA)** — 오렌지 배경+흰 텍스트 대비. → 600톤 #EA580C(대비 3.6:1, 대형
   텍스트/컴포넌트 AA) 확인, 본문 링크는 700톤 사용.
4. **범위 과대** — 뷰 45파일 일괄 변경. → 단일 Developer 위임 + Phase 4 기계 검증으로 통제.
