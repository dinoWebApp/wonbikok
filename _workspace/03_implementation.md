# 03 구현 보고: 전체 퍼블리싱 리디자인 Phase 3-A (2026-11-04)

작업자: wonbikok-developer / 범위: 플랜 §1-B (랜딩 3-B 제외) / 로직·컨트롤러·모델·라우트·헬퍼·테스트 변경 없음

## 1. 생성/수정 파일 전체 목록

**신규 (10)**
| 파일 | 내용 |
|---|---|
| `tailwind.config.js` | 디자인 토큰 (PRD 16.1) — v3 문법, v4 `@config`로 로드 |
| `app/views/shared/_button.html.erb` | 버튼 변형 파셜 (form/button_to/link/button 분기) |
| `app/views/shared/_card.html.erb` | 카드 표면 (layout 파셜) |
| `app/views/shared/_badge.html.erb` | 상태 배지 (16.2: 색상+점+텍스트) |
| `app/views/shared/_form_field.html.erb` | 라벨+입력+에러+도움말 (layout 파셜) |
| `app/views/shared/_empty_state.html.erb` | 빈 상태 (핀 모티프+CTA+보조 링크) |
| `app/views/shared/_page_header.html.erb` | 제목+설명+액션 영역 (layout 파셜) |
| `app/views/shared/_flash.html.erb` | notice(성공)/alert(오류) — 아이콘+색+텍스트 |
| `app/views/shared/_stepper.html.erb` | 온보딩 4스텝 진행 표시 (완료/현재/대기) |
| (디렉터리) `app/views/shared/` | 위 파셜 8종 |

**수정 (26)**
- 레이아웃: `app/views/layouts/application.html.erb` — 앱 셸 재구축
- 에셋: `app/assets/tailwind/application.css` — `@config` 로드 + `@layer components` (.btn-*, .field-input)
- 로케일: `config/locales/ko.yml` — 신규 키 + 표준 검증 메시지
- 인증(2): sessions/new, registrations/new
- 온보딩(4): step2~5 — 스텝퍼 추가
- 원생(7): students index/show/_form/new/edit/import_new/import_result
- 청구(4): invoices index/edit/cancel/results
- 리마인더(4): reminders index/preview/settings/history
- 대시보드(1): dashboard/show

**변경 없음 확인(git 기준)**: controllers, models, helpers, config/routes.rb, db/, test/ — 0건

## 2. 디자인 토큰 요약 (PRD 16.1 그대로)

- **배경** canvas `#F7F9FC` / **표면** surface `#FFFFFF` / **본문** ink `#191F28` / **보조** muted `#667085` / **경계선** line `#E4E7EC`
- **브랜드** brand: 50 `#EEF4FF` · 100 `#DBE7FE` · 200 `#BDD3FD` · **500 `#3478F6`**(PRD 지정 포인트·선택 상태) · 600 `#2563EB`(CTA 배경·링크, 흰 글자 AA 4.5:1) · 700 `#1D4ED8`(링크 텍스트 6.3:1)
- **성공** success 50/100/200/500/600/700 (녹색 — 완납·발행 성공) / **주의** warning (주황 — 납부 예정·확인 필요) / **오류** danger (적색 — 발행·발송 실패·조치 필요) / **정보** info (청색 — 발송 대기·안내)
- 폰트: Pretendard(jsdelivr static dynamic-subset CDN, preconnect) + 시스템 폴백 `-apple-system, system-ui, "Apple SD Gothic Neo", "Malgun Gothic", sans-serif`
- 레이아웃 토큰: 간격 4px 계열, 카드 `rounded-xl`(12px) 통일, 버튼·입력 `rounded-lg`, 그림자 0(보더만), 금액 `text-right tabular-nums`, 터치 영역 `min-h-11`(44px), 주 CTA `btn-lg`(48px)

## 3. 파셜 사용 가이드

```erb
<%# 버튼 (라벨은 동작 설명형) %>
<%= render "shared/button", label: t("..."), url: path, variant: :primary, size: :lg, class: "w-full" %>
<%= render "shared/button", label: t("..."), url: path, method: :patch, data: { turbo_confirm: t("...") } %>
<%= render "shared/button", label: t("..."), form: form  %>  <%# form.submit 경유 %>
<%# variant: :primary | :secondary | :destructive | :destructive_secondary | :warning_secondary %>

<%# 카드 (블록 필수 — layout 파셜) %>
<%= render layout: "shared/card", locals: { class: "p-5 space-y-4" } do ... end %>

<%# 배지 (tone: :neutral | :success | :warning | :danger | :info — 색+점+텍스트) %>
<%= render "shared/badge", tone: :success, text: t("invoices.status.SENT") %>

<%# 폼 필드 (블록에 입력 요소, class: "field-input" 권장) %>
<%= render layout: "shared/form_field", locals: { form: f, attr: :name,
      label_text: t("..."), hint: t("..."), required: true } do %>
  <%= f.text_field :name, class: "field-input" %>
<% end %>  <%# 에러는 form.object.errors[attr] 자동 표시 %>

<%# 빈 상태 / 화면 헤더 %>
<%= render "shared/empty_state", title: t("..."), cta_label: t("..."), cta_url: path %>
<%= render "shared/page_header", title: t("..."), description: t("...")  %>
<%= render layout: "shared/page_header", locals: { title: t("...") } do ...액션... end %>
<%# 스텝퍼/플래시: render "shared/stepper", current: 2 / render "shared/flash" %>
```

## 4. 뷰별 변경 요점

| 화면 | 요점 |
|---|---|
| layouts/application | Pretendard CDN+preconnect, sticky 헤더(핀 로고·연습 배지·로그아웃), 데스크톱(md+) 상단 내비, 모바일 하단 4탭(홈/원생/청구/알림, 아이콘+텍스트·aria-current), main pb-24 md:pb-10, shared/flash |
| sessions/new | 중앙 정렬 max-w-sm, 로고+태그라인, 카드형 폼, form_field 2개, btn-lg CTA |
| registrations/new | 동일 골격, 테넌트명·휴대폰·비밀번호·확인 form_field 필수 표기 |
| onboarding step2~5 | 스텝퍼(1~4) 추가, 카드 섹션 폼, step4 연동 준중립 배지, step5 연습=primary/실사용=secondary 이원 카드(commit 값 유지) |
| students/index | page_header(신규 CTA primary), 검색 aria-label, 필터 칩(선택=brand), 카드형 목록(형제=info·상태=success/warning/neutral·대기=핀 배지), 금액 tabular-nums 우측, 빈 상태 CTA(등록+CSV 보조) |
| students/show | 카드형 상세 dl(금액 행 tabular-nums 우측), 형제 info 안내, 이력 빈 상태(핀), 액션=수정/휴원(warning)/퇴원(destructive)/복원 |
| students/_form | 오류 요약 box(danger), 2섹션 카드(원생·보호자), 전 필드 form_field+field-input, 저장 btn-lg flex-1+취소 |
| students/new·edit | page_header + 중복 의심 warning box(new), 취소 액션 |
| students/import_new | 2단계 카드(양식 다운로드→업로드), 파일 입력 스타일링, 규칙 카드 ul |
| students/import_result | 성공/실패 count 카드(success/danger), 오류 상세 리스트, 오류행 다운로드 destructive_secondary |
| invoices/index | page_header+월 이동, 청구 만들기(primary, INV-001 주석 유지), 요약 dl+상태 카운트, 확정(확인 다이얼로그 유지), READY 체크발송(예약·datetime), 카드형 청구 목록(배지·금액 우측·수정/취소), 빈 상태 |
| invoices/edit | 기본 원비 고정 표시, 조정액(우측 tabular-nums), 변경 사유 필수(INV-002, warning 안내), 변경 이력 리스트 |
| invoices/cancel | 대상 요약(이름+배지+금액), 사유 필수(label_tag for 연결), destructive CTA+확인(INV-003) |
| invoices/results | 카드형 발송 결과(배지 통일), FAILED=danger+다시 보내기(MSG-001), QUEUED=info+예약 취소(MSG-007), SIMULATED=보조 문구, 빈 상태 CTA |
| reminders/index | page_header(설정·이력 액션), 전체 선택(Stimulus 유지), 카드형 목록(체크박스 44px, 경과일 주의 강조, 제외 배지), 제외 토글 44px 상향(MSG-004), 빈 상태 CTA |
| reminders/preview | 미리보기 카드(단계 배지, 수신자 마스킹 유지, 본문 pre), 발송+확인(15.4 확인 단계) |
| reminders/settings | 톤 라디오 카드(has-checked), 단계 체크박스 44px, 발송 시각(MSG-006 힌트), 커스텀 문구 3개, 기본 문구 미리보기 |
| reminders/history | 원생 필터 select(자동 submit 유지), 카드형 이력(배지 통일), 빈 상태 CTA |
| dashboard/show | 오늘 할 일(미납=warning·리마인더=info 숫자 카드), 마감 시작(우선 CTA=청구 만들기 btn-lg, 원생·리마인더 보조) |

## 5. 16.2 상태→배지 tone 매핑 (표준화)

- 청구: DRAFT=중립 / READY=info / SENT=success / UNPAID·OVERDUE=warning / CANCELLED=중립(오류색 아님)
- 메시지: QUEUED·SENDING=중립 / SENT·FALLBACK_SENT=success / FAILED=danger / SIMULATED=중립
- 원생: active=success / paused=warning / withdrawn=중립 / 형제=info / 이번 달 대기=중립+핀
- 색만으로 전달 금지 — 전 배지 텍스트 병행, 경고색은 조치 필요 상태에만(16.0)

## 6. 테스트·게이트 결과

| 게이트 | 결과 |
|---|---|
| `bin/rails tailwindcss:build` | 성공 (v4.3.3 엔진, 28KB) — 토큰·컴포넌트 클래스 17종 생성 확인(bg-brand-600, field-input, has-checked 등) |
| `bin/rubocop` | 85 files, **no offenses** |
| `bin/brakeman` | **0 warnings**, 0 errors |
| `bin/rails test` | **135 runs, 541 assertions, 0 failures, 0 errors** — 시스템 테스트 셀렉터 실패 0건(시스템 테스트 미존재) |
| 실행 스모크(dev 서버) | 로그인 200/303, 대시보드·원생·청구·리마인더 8화면 200, 하단탭·배지·마스킹(TEN-003 `010-****-`) 렌더 확인, 원생 등록 성공 303+플래시·422 검증 표시·중복 확인 422 플로우 재현 |

## 7. 결정 사항 (합리적 기본값)

1. **Tailwind v4 하위호환 경로**: 스택이 tailwindcss-rails 4.6.0(Tailwind v4.3.3)이므로, 지시된 v3 문법 `tailwind.config.js`를 CSS 엔트리의 `@config "../../../tailwind.config.js"`로 로드(v4 공식 하위호환). 빌드로 토큰 반영 검증 완료.
2. **Pretendard static 채택**: variable CSS는 font-family명이 "Pretendard Variable"이라 지시된 `Pretendard` 스택과 불일치 → static dynamic-subset(CDN 200 확인) 사용, family명 일치로 폴백 안전.
3. **컴포넌트 클래스(.btn-*, .btn-lg, .field-input)를 application.css `@layer components`에 정의**: 헬퍼 파일 수정 금지 조건에서 `form.submit` 등 헬퍼 생성 버튼까지 일관 적용 + 유틸리티 오버라이드 가능(components<utilities 레이어 순서). shared/_button은 변형 선택·태그 분기 담당.
4. **헬퍼 미수정**: `status_badge_class` 등 구 배지 헬퍼는 그대로 두고 뷰에서 tone 매핑 후 shared/badge 사용(구 헬퍼는 이제 미사용).
5. **layout 파셜 안전장치**: page_header/card는 `render layout:`(블록)과 positional(블록 없음) 모두 지원 — `defined?(yield)` 가드.
6. **문구**: `common.back` 값 "목록"→"목록으로"(동작 설명형), 신규 키 nav.*/onboarding.steps.*/common.required/*_empty_cta/invoices.month_nav_label/students.index.status_label 추가, 기존 키 전부 유지.
7. **ko.yml 표준 검증 메시지 추가(blank/invalid/taken 등)**: 리디자인 전부터 누락되어 422 시 "Translation missing"이 노출되던 기존 갭 — 스모크에서 발견, 로케일만 수정 허용 범위 내에서 보완. 422 응답 구조는 변경 없음(스모크로 재검증).
8. **터치 영역**: 리마인더 제외 토글 등 기존 min-h-9(36px) 행동 버튼을 44px로 상향(15.4).
9. **'콕' 핀 모티프**: 로고, empty_state 아이콘, "이번 달 대기" 배지에 적용. 상태 배지 점(dot)은 핀으로 대체하지 않음(장식 절제·가독성 우선).
10. **하단탭 활성 판정**: `request.path` prefix + 홈=`/`. **Phase 3-B에서 root를 랜딩으로 옮길 경우 홈 탭 URL을 `/dashboard`로 수정 필요**(라우트 수정 금지 조건으로 본 단계에서 미수정).

## 8. 남긴 이슈

1. **3-B 의존**: root 라우트 이동 시 레이아웃 내비의 `root_path`(홈 탭·로고 링크)를 `dashboard_path`로 갱신해야 함(레이아웃 1파일).
2. 구 배지 헬퍼(invoices_helper/students_helper의 *_badge_class) 미사용 코드화 — helpers 정리는 본 단계 범위 밖.
3. Pretendard CDN 의존(오프라인/방화벽 시 시스템 폰트 폴백 동작 — 설계 의도대로 동작하나 글자 폭 미세 변동 가능).
4. 360px 가로 스크롤: 고정폭 클래스 스캔에서 위험 요소 0건 확인했으나, 실기기 스크린 검증은 Phase 7 Tester 반응형 테스트에서 최종 확인 권장.

---

# 03 구현 보고: 랜딩페이지 신규 Phase 3-B (2026-11-04)

작업자: wonbikok-developer / 범위: 플랜 §1-A (랜딩 일체 — 라우트·컨트롤러·BetaApplication·뷰·SEO) / PRD 13장·11.1 준거

## 1. 생성/수정 파일 목록

**신규 (18)**
| 파일 | 내용 |
|---|---|
| `db/migrate/20261104000001_create_beta_applications.rb` | beta_applications 테이블 + [contact_type, contact_value] 인덱스(중복 최소 식별용) |
| `app/models/beta_application.rb` | 암호화(encrypts deterministic)·검증(필수/선택/동의 분리)·연락처 정규화·with_contact 스코프 |
| `app/controllers/landing_controller.rb` | show — 인증 시 /dashboard 303 리다이렉트, 비인증 랜딩 렌더(게이트 2종 skip, landing 레이아웃) |
| `app/controllers/beta_applications_controller.rb` | new/create/done — rate_limit(10회/1시간), 중복 신청 정상 완료 처리, 422 시 landing/show 재렌더 |
| `app/views/layouts/landing.html.erb` | 랜딩 전용 레이아웃 — SEO 메타(title/description/OG)·헤더(로고+CTA)·푸터(소개·문의만)·본문 바로가기 |
| `app/views/landing/show.html.erb` | 10섹션 + 베타 폼 구성 |
| `app/views/landing/_hero.html.erb` | 헤드라인 A형 + 설계 목표 각주 + 모바일 프레임 CSS 목업(role=img·aria-label) |
| `app/views/landing/_problems.html.erb` | 페인 카드 3종 (13.3 문구 그대로) |
| `app/views/landing/_solution.html.erb` | 월간 사이클 4스텝 + 소요 시간 배지 (PRD 5장 랜딩 버전) |
| `app/views/landing/_features.html.erb` | 기능 3카드 + CSS 미니 목업, 현금영수증 "연동 준비 중" 병기 |
| `app/views/landing/_regulation.html.erb` | 규제 안내 카피(13.3 그대로) + 국세청 링크(nts.go.kr) |
| `app/views/landing/_demo.html.erb` | 정적 4스텝 모형(체크→알림톡 도착) + GIF 준비 중 안내 |
| `app/views/landing/_social_proof.html.erb` | 파일럿 30곳 모집 배너 + 평생 50% 배지(후기 미확보 대체) |
| `app/views/landing/_pricing.html.erb` | 2플랜 카드 + 월간/연간 토글(라디오+peer 변형, JS 0) + "파일럿 검증 전 가격" 각주 |
| `app/views/landing/_plan_card.html.erb` | 11.1 표 기반 플랜 카드(지원/미지원 색+텍스트 병행) |
| `app/views/landing/_faq.html.erb` | 8문답 details/summary 아코디언 + data-event="faq_open" |
| `app/views/landing/_beta_form.html.erb` / `_final_cta.html.erb` | 신청 폼 섹션(id=beta) / 최종 CTA(cta_final) |
| `app/views/beta_applications/_form.html.erb` / `new.html.erb` / `done.html.erb` | 신청 폼(필수/선택/동의 분리)·독립 페이지·완료 화면(SLA 문구 없음) |

**수정 (10)**
| 파일 | 변경 |
|---|---|
| `config/routes.rb` | `root "landing#show"` + `get "/dashboard"`(as: :dashboard) 이동 + `resources :beta_applications`(new/create/done) |
| `app/controllers/sessions_controller.rb` | 로그인 성공 리다이렉트 root_path→dashboard_path(이동된 앱 홈 1회 리다이렉트 유지) |
| `app/controllers/onboarding_controller.rb` | 온보딩 완료·완료자 우회 리다이렉트 root_path→dashboard_path(동일 사유) |
| `app/views/layouts/application.html.erb` | 로고 링크·홈 탭(데스크톱/모바일) root_path→dashboard_path + 활성 판정 `"/"→"/dashboard"` (3-A가 남긴 이슈 #1 처리) |
| `config/locales/ko.yml` | landing 네임스페이스(전 카피)·beta_applications·enums.student_count_range·activerecord 속성·accepted/invalid_email 메시지 추가, 기존 키 전부 유지 |
| `test/controllers/sessions_controller_test.rb` | root_path→dashboard_path 1곳 |
| `test/controllers/onboarding_controller_test.rb` | `get root_path`→`get dashboard_path` 1곳, assert 대상 root_path→dashboard_path 3곳 |
| `test/integration/invoices_flow_smoke_test.rb` | assert 대상 root_path→dashboard_path 1곳 |
| `db/schema.rb` | beta_applications 반영(마이그레이션 실행) |

## 2. 라우트 변경 내역

- 변경 전: `root "dashboard#show"` (루트 = 대시보드, 인증 게이트 경유 로그인 리다이렉트)
- 변경 후: `root "landing#show"`(비인증 랜딩 렌더·인증 시 /dashboard 303) / `get "/dashboard", to: "dashboard#show", as: :dashboard`
- 신규: `resource`스러운 `resources :beta_applications, only: %i[new create]` + collection `get :done`(PRG 패턴용 완료 화면)
- 온보딩 게이트·인증 게이트는 Landing/BetaApplications 컨트롤러에서 skip(공개 페이지), dashboard는 기존 게이트 유지

## 3. 테스트 수정 목록 (기계적 치환만, 로직 변경 없음)

| 파일 | 위치 | 수정 |
|---|---|---|
| sessions_controller_test.rb | "로그인 성공 시…" assert | root_path → dashboard_path |
| onboarding_controller_test.rb | CRITICAL-2 `get root_path` | get dashboard_path (앱 홈 진입점 치환) |
| onboarding_controller_test.rb | 온보딩 완료자 2곳·연습 모든 완료 1곳 assert | root_path → dashboard_path |
| invoices_flow_smoke_test.rb | log_in_as assert | root_path → dashboard_path |

- 근거: 로그인·온보딩 완료 후 서버 리다이렉트 대상이 "앱 홈"이며 앱 홈이 `/`→`/dashboard`로 이동. 세션·온보딩 컨트롤러의 redirect_to 대상을 dashboard_path로 갱신하지 않으면 `/`→랜딩→`/dashboard` 2중 리다이렉트가 발생하므로 컨트롤러 1라인씩 동반 갱신(행위 동일·리다이렉트 1회 유지).

## 4. Rule ID 준거 결과

- **TEN-002**: BetaApplication에 주민번호·생년월일 등 금지 항목 필드 없음(이름·호칭·연락처·유형·선택 3항목·동의 2개만)
- **TEN-003**: `encrypts :contact_value, deterministic: true`(User.phone_number와 동일 체계) — DB raw 값 암호문 확인, 화면 노출 없어 마스킹 불요
- **TEN-006 준용**: IP·UA·추적 필드 미수집(폼 하단에 "부가 정보 미저장" 고지), 중복 감지는 contact 동등 조회 1회
- **13.4**: '반나절→15분' 설계 목표 각주, 미제공 기능 "연동 준비 중"/"준비 중" 병기, 후기 대신 모집 배너, 인증마크 없음, 가산세는 사실 나열+안심 마무리
- **13.8**: 푸터는 서비스 소개·문의 메일·© 1행뿐 — 사업자 정보·개인정보처리방침 등 미확정 법정 고지 미생성
- **13.5**: 외부 스크립트 0, data-event만(cta_hero/cta_pricing/cta_final/faq_open/form_start/form_submit/form_error)

## 5. 게이트·스모크 결과

| 게이트 | 결과 |
|---|---|
| `bin/rails db:migrate` (dev·test) | 성공, schema.rb 반영 |
| `bin/rails test` | **135 runs, 541 assertions, 0 failures, 0 errors** |
| `bin/rubocop` | 89 files, no offenses |
| `bin/brakeman` | 0 warnings |
| `bin/rails tailwindcss:build` | 성공 (peer-checked/annual·has-checked·scroll-mt 등 랜딩 클래스 생성 확인) |
| 스모크(dev 서버) | 비인증 `/` 200+카피·메타·data-event 검증 / 정상 제출 303→done 200 / 무동의·형식 오류 422+오류 요약(form_error) / 동일 연락처 재제출 303·레코드 미증가(중복 감지) / 전화 하이픈 정규화(01012345678) / 연락처 암호문 저장·복호화 일치 / 인증 `/`→303 `/dashboard`, 비인증 `/dashboard`→302 로그인 / 360px 가로 오버플로 0건(뷰포트 검사) / 브라우저 스크린샷 검증(모바일 히어로·폼·요금 토글·FAQ·푸터) |

## 6. 결정 사항 (합리적 기본값)

1. **중복 신청 처리**: `valid?` 통과 + contact 동등 조회 존재 시 새 레코드 없이 동일 완료 화면 303(13.6 "민감하게 노출하지 않는다"). deterministic 암호화가 조회를 가능케 함.
2. **호칭·유형 저장 방식**: title/academy_type은 원문 문자열(원장님/교습소 등) 저장 — Tenant.business_type enum(한글 값) 선례 준수. student_count_range는 키 저장("1_15" 등, YAML 숫자 파싱 방지 위해 따옴표)+ko.yml 라벨.
3. **rate limit**: Rails 8 내장 `rate_limit to: 10, within: 1.hour, only: :create, with: :rate_limited` — 초과 시 랜딩으로 alert 리다이렉트(429 대신 친화 안내). CAPTCHA 등 미도입(과투자 금지).
4. **422 시 랜딩 전체 재렌더**: `render "landing/show", status: :unprocessable_entity` — 임베드 폼의 오류를 유지. 페이지 최상단에서 폼으로 스크롤이 자동 이동하지 않는 한계는 남김(§7-3).
5. **요금 토글 JS 0 구현**: sr-only 라디오 2개 + named peer 변형. 1차 구현에서 라디오와 가격 그룹이 형제가 아니어서 토글이 카드에 적용되지 않는 버그를 브라우저 검증으로 발견 → 라디오·라벨·가격 그룹을 모두 형제로 배치해 수정(구조상 제약: Tailwind peer는 형제 결합자). display 유틸리티 충돌 회피 위해 표시 전환 래퍼(hidden/peer-checked:block)와 grid 내부 분리.
6. **폼 배치**: 13.6 지시 옵션 중 "10 앞"(FAQ와 최종 CTA 사이). 최종 CTA 버튼은 #beta 앵커로 폼을 다시 노출.
7. **목업 톤**: 알림톡 목업에 카카오 옐로 대신 토큰 색(중립·브랜드) 사용 — 16.0 색채 규율(주색 1) 유지. 목업에 표시되는 샘플 이름·금액도 ko.yml 관리.
8. **문의 채널**: `support@wonbikok.kr` 플레이스홀더(ko.yml 1키) — 실제 운영 콘택트 확정 시 1키 교체. © 1행은 사업자 정보 아닌 서비스명 표기 수준으로 한정.
9. **seo**: og:url/og:image는 도메인·에셋 미확정으로 생략(13장 확정 사항 명시적 허용 범위).
10. **베타 폼 완료 문구**: "모집 진행 상황에 따라 안내드리겠습니다" — 시간 약속(SLA) 표현 배제.

## 7. 남긴 이슈

1. **베타 폼 신규 테스트 미작성**: 플랜 §5 위임표 기준 신규 테스트는 Phase 7 wonbikok-tester 몫(유효성·동의·암호화·중복). 본 단계는 기존 테스트 회귀 수정만 수행(완료 기준 #1 준수). 스모크로 동작은 검증 완료.
2. **랜딩 헤더 CTA가 모바일 좁은 폭에서 길어질 수 있음**: 현재 360px 검증 통과(버튼 1행 유지), 실기기 확인은 Tester 반응형 테스트 권장.
3. **422 재렌더 시 폼 위치로 자동 스크롤 없음**: 서버 렌더 한계 — 오류 요약 박스에 data-event="form_error" 마킹만. JS 도입 시 앵커 스크롤 보강 가능.
4. **랜딩 폼 스팸 방지 수준**: IP 기반 rate limit만. 파일럿 모집 후 필요 시 hidden honeypot/CAPTCHA 검토.
5. **docs 이슈**: PRD 13장 "구현 확정 사항"은 Phase 2에서 이미 반영됨(02_prd_update.md). 본 단계에서 추가 문서 변경 없음.

---

# 03 구현 보고: Phase 6 — Reviewer 지적 사항 최소 수정 (2026-11-04)

> 05_review.md 지적 사항만 수정 (범위 외 변경 없음). Rule ID 준거: TEN-003 (CRITICAL-1·WARNING-2), 13.4 (WARNING-3), AGENTS.md 문구 관리 규칙 (WARNING-4), 15.4 (INFO-5).

## 1. 수정 내역 (항목별)

### [CRITICAL-1] 로그 평문 노출 차단 — TEN-003
- `config/initializers/filter_parameter_logging.rb`: `filter_parameters`에 `:contact_value, :phone_number` 추가(부분 일치 마스킹). 베타 폼 `beta_application[contact_value]`와 기존 sessions/registrations `phone_number` 평문 로그를 동시 차단.
- **스모크 검증**: dev 로그에서 `contact_value => "[FILTERED]"` 확인, 제출값 원문 0건.

### [WARNING-2] 중복 신청 경쟁 조건 — TEN-003 준용·멱등성
- `db/migrate/20261104000001_create_beta_applications.rb`: `[contact_type, contact_value]` 인덱스 `unique: true`로 변경. 주석에 title/academy_type 저장 방식 갱신(WARNING-4와 동반). 운영 데이터 없어 기존 마이그레이션 직접 수정.
- `app/controllers/beta_applications_controller.rb`: save 경합 시 `ActiveRecord::RecordNotUnique` rescue → 완료 화면 303 멱등 종결(`save_idempotently` private 래퍼, "이미 신청" 노출 없음 유지).
- **스모크 검증**: 정상 제출 303→done / 동일 연락처 재제출 303·레코드 1건 유지 / sqlite 직접 중복 INSERT → `UNIQUE constraint failed` 확인.

### [WARNING-3] 현금영수증 "준비 중" 병기 — 13.4
- `config/locales/ko.yml`: `landing.solution.step2_copy` 말미에 "(현금영수증 연동 준비 중)" 병기, `landing.pricing.plan_supported_pending: "지원 (연동 준비 중)"` 신설.
- `app/views/landing/_pricing.html.erb`: 라이트·스탠다드 양 플랜의 현금영수증 행 값을 `plan_supported_pending`으로 교체(다른 "지원" 행은 유지).

### [WARNING-4] 폼 옵션 라벨 ko.yml 통일 — AGENTS.md 문구 관리 규칙
- `app/models/beta_application.rb`: `TITLE_OPTIONS = %w[principal teacher other]`, `ACADEMY_TYPE_OPTIONS = %w[academy study_room other]` — 한글 문자열 → 키 값 저장. `student_count_range`와 동일 패턴으로 통일(같은 폼 내 방식 혼재 해소).
- `config/locales/ko.yml`: `enums.beta_application.title.*`, `enums.beta_application.academy_type.*` 라벨 매핑 추가(`tenant.business_type`의 `study_room: 공부방` 키 관례 준수).
- `app/views/beta_applications/_form.html.erb`: 두 select를 키×라벨 map 방식으로 변경. 저장 데이터 없어 데이터 전환 불필요.
- **스모크 검증**: 저장값 `principal`/`academy`/`1_15`(키), 렌더 옵션 `<option value="principal">원장님</option>` 등 한글 라벨 확인.

### [INFO-5] 연락처 입력 접근성 — 15.4
- `app/views/beta_applications/_form.html.erb`: 연락 수단 라디오 선택에 따라 단일 입력의 `inputmode`/`autocomplete`을 tel/email로 전환하는 미니 인라인 스크립트 추가(422 재렌더 시 phone 서버 선택 상태도 초기 반영).
- **방식 선택**: 두 입력 CSS 전환은 숨김 input도 제출돼 params가 덮어쓰이는 문제(dom 순서 의존)가 있어 단일 입력 속성 전환 택함. CSP 이니셜라이저는 전부 주석 상태(비활성)라 인라인 스크립트 가능. Stimulus 도입 없음.

### 미반영 (기록만 — 05_review.md 지적 유지)
- **INFO-6**(`support@wonbikok.kr` 플레이스홀더): 실제 수신함 확정 시 1키 교체 예정 — 배포 전 체크리스트 항목. 코드 변경 없음.
- **INFO-7**(invoices 뷰 직접 쿼리): 본 변경 범위 밖(기존 코드 유지분). W3 청구 확장 시 컨트롤러 이관.
- **INFO-8**(allow_browser 완화): 현장 데이터 확보 전까지 `versions: :modern` 유지가 합리적(리뷰어도 합리적 선택으로 언급).
- **INFO-9**(목업 "11월 원비" 월 표기): 실에셋 교체 시점에 함께 정리.

## 2. 생성/수정 파일 목록 (Phase 6)

| 파일 | 변경 |
|:---|:---|
| config/initializers/filter_parameter_logging.rb | CRITICAL-1 |
| db/migrate/20261104000001_create_beta_applications.rb | WARNING-2 (+주석 갱신) |
| app/controllers/beta_applications_controller.rb | WARNING-2 |
| config/locales/ko.yml | WARNING-3·4 |
| app/views/landing/_pricing.html.erb | WARNING-3 |
| app/models/beta_application.rb | WARNING-4 |
| app/views/beta_applications/_form.html.erb | WARNING-4·INFO-5 |
| db/schema.rb | unique: true 반영 |

## 3. 게이트·검증 결과

| 항목 | 결과 |
|:---|:---|
| `bin/rails db:migrate` (dev) | 성공 — rollback→re-migrate, dev DB `CREATE UNIQUE INDEX` 확인 |
| `RAILS_ENV=test bin/rails db:migrate` | 성공(exit 0) — 단, test DB는 schema_sha1 메타에 따라 schema.rb에서 구성되므로 `db:test:prepare`로 재구성(§4 참조) |
| db/schema.rb | `unique: true` 반영, prepare 후 체크섬 불변 확인 |
| `bin/rubocop` | 89 files inspected, no offenses |
| `bin/brakeman` | No warnings found |
| `bin/rails test` | **135 runs, 541 assertions, 0 failures, 0 errors, 0 skips** (기존 135건 회귀 없음) |
| 스모크(dev 서버 :3100, curl) | 정상 제출 303→done / 중복 재제출 303→done·레코드 1건 / sqlite 중복 INSERT → UNIQUE constraint failed / 로그 `contact_value => "[FILTERED]"`·원문 0건 / 옵션 키 저장+한글 라벨 렌더 / "연동 준비 중" 6곳 렌더 / INFO-5 스크립트 렌더(라인 850+) |
| 정리 | 스모크 레코드 삭제(dev beta_applications 0건), 서버 종료·pid 제거 |

## 4. 결정 사항 / 트러블슈팅 기록

1. **test DB 재구성 절차**: dev migrate 직후 `RAILS_ENV=test bin/rails db:migrate`가 스테일한 test DB(구 non-unique 인덱스)에서 schema.rb를 재덤프해 `unique: true`를 덮어쓰는 문제 발견 → 순서 확정: ① dev `db:schema:dump` ② 스테일 병렬 샤드(`storage/test.sqlite3_0..7`) 삭제 ③ `bin/rails db:test:prepare` ④ 체크섬으로 schema.rb 불변 확인. 향후 마이그레이션 변경 시 동일 절차 권장.
2. **INFO-5 방식**: 위 §1 참조(두 입력 전환의 params 덮어쓰기 문제로 미니 인라인 스크립트 선택). no-JS 환경에서는 서버 기본값(email 힌트) 유지.
3. **RecordNotUnique rescue 경로**: 정상 중복은 `duplicate_submission?`(exists?)가 먼저 흡수하므로 rescue는 동시 제출 경합 전용. 단일 스레드 스모크로는 exists? 경로가 발동 — rescue 분기는 유니크 제약 실증(sqlite INSERT 실패)으로 정합성 확인.
