# 03_implementation.md — 전체 퍼블리싱 재구성 (웜 오렌지 에디토리얼)

- 작성일: 2026-11-04
- 기준: PRD 16.1 v2.4, 01_plan.md §3~4

## 변경 파일 (총 22개 + 빌드 산출물)

### 설정/토큰 (2)
- `tailwind.config.js` — canvas/ink/muted/line/brand 6단계/info 전면 교체.
  success/warning/danger·fontFamily 유지. 주석 오렌지 기준 갱신.
- `app/assets/tailwind/application.css` — 헤더 주석 갱신(라운드 넉넉히·소프트 섀도·
  2026-11-04 재구성 명시). btn-*/field-input은 토큰 참조라 자동 반영.

### 레이아웃 (2)
- `app/views/layouts/application.html.erb` — 핀 로고 SVG `#3478F6`→`#EA580C`(fill 2곳).
  탭 active·로고 외 색은 토큰 클래스라 자동 반영. 연습 모드 배지 warning 유지.
- `app/views/layouts/landing.html.erb` — 로고 SVG 3벌(헤더·푸터) 동일 교체.
  헤더·푸터 톤은 line/canvas/brand 토큰 자동 반영.

### shared 파셜 (3)
- `_card` / `_empty_state` — `rounded-xl`→`rounded-2xl` + `shadow-sm` (PRD 16.1 표현력 상향).
- `_badge` — 전 tone에 `border border-{tone}-200` 추가: 브랜드 오렌지와 앰버 배지 구분
  (연한 배경+테두리 조합, 불변 원칙 6번). neutral도 slate-200 테두리.
- `_button`/`_flash`/`_form_field`/`_page_header`/`_stepper` — 토큰 참조, 무변경(자동 반영).

### 랜딩 (6)
- `_hero` — 섹션 배경 `bg-surface`→`bg-gradient-to-b from-brand-50 to-canvas`(웜 그라데이션).
  목업 프레임 `border-ink/80`→`/70` + `shadow-xl`(웜톤 소프트화).
- `_solution` / `_demo` — 스텝 리스트·노트 카드 `rounded-2xl`+`shadow-sm`.
- `_plan_card` — `rounded-2xl`+`shadow-sm`, 신규 `featured` local(브랜드 600 2px 테두리 +
  플랜명 오렌지 강조). i18n 키 추가 금지 원칙에 따라 추천 배지 문구 없이 테두리·색으로만 강조.
- `_pricing` — standard_plan 렌더에 `featured: true` 전달(월간/연간 그룹 모두).
- `_social_proof` — 로고 SVG 하드코딩 교체만. 나머지 5파셜(problems/features/regulation/
  faq/final_cta/beta_form)은 토큰 참조로 자동 반영 — 무변경.

### 앱 화면 (9)
- 카드형 컨테이너(`rounded-xl border border-line bg-surface`)→`rounded-2xl shadow-sm` 일괄:
  students/index·import_result, invoices/index·results, reminders/index·preview·history,
  beta_applications/_form(canvas 박스). 경고·오류·안내 콜아웃(warning/danger/info 배경)은
  의미상 알림이라 `rounded-xl` 유지.
- dashboard — info 토큰이 오렌지 스케일로 바뀌어 리마인더 숫자 강조가 자동 오렌지화. 무변경.

## 주요 디자인 결정

1. 배지 오렌지/앰버 구분: `_badge`에 테두리 추가로 해결(계획 §8 리스크 1 대응).
2. 대표 요금제 강조: i18n 불변 원칙 준수를 위해 배지 문구 없이 border-2 brand-600 +
   플랜명 텍스트 색으로 표현.
3. 경고/오류 콜아웃은 카드가 아닌 알림 성격으로 보아 rounded-xl 유지(과한 통일 방지).
4. 뷰의 토큰 클래스(border-line 등)는 config 교체로 자동 반영 — 클래스명 변경 없음.

## 검증 결과

- `grep -rn "3478F6|2563EB|1D4ED8|구 청색 팔레트" app/ tailwind.config.js` → 0건
  (app/assets/builds/tailwind.css는 빌드 재생성으로 갱신 확인 — tailwindcss v4.3.3 Done).
- `bin/rails test` → 170 runs, 734 assertions, 0 failures, 0 errors, 0 skips.
  테스트 파일 수정 불요(셀렉터 의존 테스트 없음).

## 남은 리스크

1. brand-500(#F97316) 배경+흰 텍스트 조합이 생기면 대비 부족 — 현재 CTA는 전부 600 사용,
   신규 화면에서 500 배경+흰 글자 조합 금지(본문 링크 700).
2. `_plan_card` featured는 두 번째 인자 순서 의존 없이 local 전달이라 기존 호출부(probes 등
   타 뷰)에 영향 없음 확인(호출부는 _pricing 2곳뿐).
3. 빌드된 CSS(app/assets/builds/tailwind.css)는 커밋 대상 — 테스트 실행 시 자동 재생성 확인.
