# 05_review.md — 전체 퍼블리싱 재구성 (웜 오렌지 에디토리얼) 코드 리뷰

- 리뷰일: 2026-11-04
- 리뷰어: wonbikok-reviewer-lite
- 대상: 커밋 전 diff 20파일 (+60/-56) — app/views 17 · app/assets/tailwind/application.css · tailwind.config.js
- 기준: 01_plan.md §3~4·§8, 02_prd_update.md, PRD.md 16장 v2.4

## 상태: APPROVED

BLOCKER 0 · CRITICAL 0 · WARNING 1 (기록·보강 권장)

## 체크리스트별 결과

| # | 항목 | 판정 | 근거 |
|---|---|---|---|
| 1 | 뷰 로직 불변 | PASS | `config/locales`·`config/routes.rb`·controllers·models diff 0건. diff 내 `data-*` 속성 삭제 0건. `_plan_card`는 `local_assigns.fetch(:featured, false)` 추가만(미전달 시 기존 동작 보존). link_to 인자·폼 필드·t() 키 불변. 유일한 로직 추가인 featured local 호출부는 `_pricing` 4곳뿐(62·64·71·73행) 확인 |
| 2 | TEN-003 마스킹 표시 | PASS | 식별정보 표시 뷰 미변경. `invoices/index.html.erb:91` student_name_snapshot(TEN-004 스냅샷) 표시 유지 |
| 3 | 상태색 도메인 의미 보존 | PASS | `git show HEAD:tailwind.config.js` 대조 — success/warning/danger 값 블록 동일(warning 주석 1행만 추가). `invoices/index.html.erb:96`·`results.html.erb:18` tone 매핑(DRAFT/QUEUED=neutral 등) 불변 |
| 4 | brand↔warning 배지 구분 | PASS | `shared/_badge.html.erb:11-15` 전 tone에 `border border-{tone}-200` 추가. warning(#FFFAEB/#FEDF89/#B54708 앰버) vs brand·info(#FFF4ED/#FDDCB5/#C2410C 오렌지) 배경·테두리·텍스트 3중 차별. CTA(solid brand-600+흰 글자, application.css:14)와 배지(연배경+테두리+진한 텍스트) 구조적으로 상이. 16.2 "색만으로 상태 전달 금지"는 텍스트 병행으로 충족 |
| 5 | 토큰 교체 정확성 | PASS | tailwind.config.js 18-30·61-69행 — canvas #FAF8F5·ink #1D1A16·muted #6B655D·line #E8E2D9·brand 50~700(#FFF4ED/#FFE8D9/#FDDCB5/#F97316/#EA580C/#C2410C)·info=brand 동일 스케일. PRD 16.1 v2.4 표와 정확히 일치 |
| 6 | 청색 잔존 | PASS | 구 청색 hex(3478F6/2563EB/1D4ED8/EEF4FF/DBE7FE/BDD3FD) app/·config 0건, `blue-*` 클래스 0건, 빌드 CSS(app/assets/builds/tailwind.css, 재생성 2026-11-04 10:44)에서 구 청색 0건·신규 색 포함. 구 뉴트럴 hex(F7F9FC/191F28/667085/E4E7EC)도 0건 |
| 7 | a11y 유지 | PASS | min-h-11 레이아웃 6곳(application 4·landing 2) 유지, btn-primary/field-input min-h-11 유지(application.css:14·41). aria-label·role="note" 보존. `bg-brand-500`/`bg-info-500` 흰 글자 조합 0건 — CTA·solution 스텝 번호는 전부 600 |
| 8 | 무수정 뷰 정당성 | PASS | 미수정 뷰 샘플 4종 전부 shared 파셜·토큰 경유 오렌지화 확인: dashboard/show(shared/card+info 토큰), students/show(card+badge+info 콜아웃), registrations/new(card+form_field+btn-primary+text-brand-700 링크), onboarding/step2(stepper+card+btn-primary). 직접 청색 보유 미수정 뷰 0건 |
| 9 | 과도한 마크업 삭제 | PASS | diff 전수 검토 — 삭제 라인은 전부 클래스 문자열·SVG fill hex·주석 교체. 텍스트·요약·역할 속성·i18n 키·폼 필드 손실 0건 |

## 발견 사항

### WARNING
1. [WARNING] PRD 16.1 — `app/views/shared/_badge.html.erb:11-15` — 배지 구분 3요소(연한 배경+테두리+아이콘) 중 아이콘은 파셜 차원에서 강제되지 않음(호출부 선택). 현재는 텍스트 병행(16.2)과 배경·테두리 차별로 CTA와의 구분이 확보되어 문제 없음. — 제안: 향후 brand(info) 배지와 warning 배지가 나란히 배치되는 신규 화면(청구 상세 등)에서는 핀·시계 아이콘 병행을 권장.

### 관찰 (기록 수준, 조치 불요)
- info 토큰의 오렌지화로 인한 파급: dashboard 리마인더 숫자 강조, students 형제 배지/콜아웃, invoices READY 배지가 오렌지로 표시됨 — 토큰 교체의 의도된 귀결이며 PRD 16.1 v2.4(info=오렌지 공용)와 정합. 뷰 tone 매핑을 건드리지 않은 판단이 옳음(로직 불변 원칙).
- `_badge` neutral 톤의 slate 계열 유지 — 기존부터 slate였고 색채 규율(16.0)의 강조색이 아니므로 허용 범위.
- `_hero` 히어로 그라데이션(from-brand-50 to-canvas) — 플랜 §2 폰코 보조 레퍼런스(랜딩 컬러 배경) 근거 명시됨. ink 텍스트 대비 충분.

## 판정: APPROVED

- BLOCKER 0, CRITICAL 0 — 커밋 진행 가능.
- WARNING 1건은 보강 권장 사항으로 파이프라인 진행을 막지 않음.

## Tester 중점 제안 (Phase 7)

- landing pricing: featured local 전달 경로(월간·연간 그룹 모두 standard_plan 강조 렌더) 스모크.
- shared/badge 전 tone 렌더 경로(invoices index/results, reminders history) 회귀.
- 구현 보고대로 뷰 셀렉터 의존 테스트는 없음 — 전체 회귀 1회로 충족 가능.
