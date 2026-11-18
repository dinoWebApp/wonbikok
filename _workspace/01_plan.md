# 01_plan.md — W4 병렬 배치: F7 대시보드 + F8 구독·결제 + 관리자 A1·A2·A3

- 작성일: 2026-11-18
- 파이프라인: **병렬 배치 (§6.14)** — `0 → 1-P → ✋승인(배치 1회) → 2 → 3-P(f7∥f8∥admin, 상한 3) → 3-S(통합) → 4 → 5 → 6? → 7-P? → 7-S → 8 → 9`
- 프로필(일반 모드): wonbikok-developer / wonbikok-reviewer / wonbikok-tester
- A5(현금영수증 발행 관리)는 본 배치 제외 — A1·A2·A3 이후 별도 태스크(AGENTS 후보 조합 준수)

## 0. 범위 확정 결정 (오케스트레이터 판단 — 승인 대상)

1. **F8 v1.0 최소형**: PRD "정기결제 도입 전(P1 이전) 수동 결제·파일럿 무료 운영 대체 가능" 조항 채택 —
   실제 카드 결제·빌링키 발급은 **포트원 어댑터 SIMULATED**(바로빌/솔라피 패턴 준용, 포트원 키 미등록).
   구현: Subscription 도메인(30일 체험 자동 시작·플랜·상태 전이)·SUB-001 상한 차단·D-7 알림(Recurring·
   SIMULATED)·수동 결제 기록·결제 실패 재시도 프레임(상태 전이 중심).
2. **F7 PDF 저장은 후속 과제** — 마감 리포트는 HTML 화면으로 구현(Node/npm 없는 스택에서 PDF 젬
   선정[prawn 등]·플랜 게이팅은 F8 상태 의존이라 별도 태스크로 분리).
3. **관리자 OTP**: A0 이메일+비밀번호+2단계 인증 — 로컬/1인 운영에 맞는 **사전 공유 시크릿 기반 6자리
   TOTP 간단 구현**(외부 젬 불필요 수준, 데이터 모델은 확장 가능 설계). 별도 주소는 라우트 네임스페이스로
   분리(운영 배포 시 서브도메인 격리 가능 구조).
4. **A2·A3의 Subscription 참조**: 병렬 의존 해소를 위해 **Subscription 시그니처를 본 플랜에서 사전 고정**
   (아래 §2) — admin 태스크는 이 가정으로 작성, 3-S에서 대조·결선(F4/F9 성공 패턴).

## 1. 태스크 분해·소유권 표

| task | 범위 | 소유 파일 | 공유(3-S) |
|---|---|---|---|
| **f7** 마감 대시보드 | 이번 달 청구/수납/미납/납부율+기준 명시·오늘 할 일(미확인 입금·발행 실패·리마인더 예정) 상단·빠른 작업·미발행 잔여 경고(월말 가산세 문구)·마감 리포트 HTML·원생별 수납 이력(students/show)·빈 상태 온보딩 | `app/controllers/dashboard_controller.rb`(수정)·`app/views/dashboard/*`(수정)·`app/services/dashboard/summary_service.rb`(신규)·`app/views/students/show.html.erb`(수정 — 이력 섹션만)·`test/services/dashboard/*`·`test/controllers/dashboard_controller_test.rb` | routes·ko.yml |
| **f8** 구독·결제 | Subscription(§2 시그니처)·가입 시 30일 체험 자동 시작·SUB-001 원생 상한 차단(students create 가드)·플랜 표시·수동 결제 등록(사유)·결제 실패 3회 재시도 상태 프레임(SUB-002)·체험 D-7 알림 Job(SIMULATED)·구독 화면(플랜·상태·결제 이력) | `app/models/subscription.rb`·`app/services/subscriptions/*`(trial_start·plan_change·payment_record·retry_policy)·`app/services/portone/billing_service.rb`(SIMULATED)·`app/controllers/subscriptions_controller.rb`·`app/views/subscriptions/*`·`app/controllers/students_controller.rb`(수정 — 상한 가드만)·`app/controllers/registrations_controller.rb`(수정 — 체험 시작 훅만)·`test/**` | 마이그레이션·routes·ko.yml·`config/recurring.yml` |
| **admin** A1·A2·A3 | A0 공통(AdminUser 이메일+비밀번호+OTP·감사 로그·마스킹 원칙)·A1 운영 대시보드(24h 실패·지표·대응 대기 큐)·A2 이용자 관리(통합 검색·상세·이벤트 타임라인·조치[플랜 변경·체험 연장 30/60 상한·정지] — ADM-001 사유 필수)·A3 구독·결제 관리(결제 이력·실패 모니터링 D+30 카운트다운·환불 분기·매출 집계) | `app/models/admin_user.rb`·`app/models/audit_log.rb`·`app/controllers/admin/`(base·sessions·dashboards·tenants·subscription_payments)·`app/views/admin/**`·`app/views/layouts/admin.html.erb`·`app/services/admin/`(tenant_timeline·refund_policy)·`test/**` | 마이그레이션·routes(`Admin::`)·ko.yml |
| **integ**(3-S) | 마이그레이션 **1회**: subscriptions·admin_users·audit_logs / routes 결선(subscriptions 리소스·Admin 네임스페이스·대시보드는 기존) / ko.yml 병합 / `config/recurring.yml`(체험 D-7·필요시 결제 재시도 배치) / Subscription 시그니처 대조(f8 vs admin 가정) / 앱 레이아웃 네비에 구독 진입 추가 / 전체 게이트 선행 | — | 전부 |

## 2. Subscription 시그니처 사전 고정 (f8·admin 공통 가정 — 3-S 대조 기준)

- 컬럼: `tenant_id(유니크)`·`plan(light/standard)`·`status(trial/active/past_due/suspended/cancelled)`·
  `trial_started_at`·`trial_ends_at`·`current_period_start`·`current_period_end`·`cancel_scheduled_at`
- 메서드(예상): `trial_remain_days`·`plan_limit(:students)`→ {light: 30, standard: 70}·`trial_expiring?(days:)`
- 수동 결제 기록은 `subscription_payments` 대신 **본 배치에서 Subscription에 1:N `admin/payment_records`?
  → 단순화: `PaymentRecord` 모델 추가는 과대 — A3 결제 이력은 `SubscriptionEvent` 이벤트 소스(타입:
  trial_started/manual_payment/payment_failed/retry/past_due/suspended/plan_changed/refund)로 통일 —
  **이벤트 타임라인(A2)과 결제 이력(A3)을 동일 테이블 `subscription_events`로 서빙**(생성: f8 도메인 서비스)
- 포트원 빌링키: 실발급 SIMULATED — `billing_key_uid` 컬럼은 v1.0 제외(필요 시 P1 추가)

## 3. 병렬 판정 (3조건)

1. 소유권 분리: 위 표 — 교차 없음(students_controller=f8·students/show 뷰=f7으로 분리 배정) ✅
2. 의존 없음: f7은 기존 도메인(invoices·payments·cash_receipts) 읽기만·admin은 Subscription §2 가정 ✅
3. 공유 파일 비수정: routes·마이그레이션·ko.yml·recurring.yml·레이아웃 전부 3-S ✅

## 4. fan-out 공통 제약 (각 Developer 프롬프트 포함)

소유권 화이트리스트·자기 파일 rubocop만·전체 테스트/마이그레이션/서버 기동 금지(3-S 후)·문서 수정 금지·
컬럼은 §2 가정(불일치는 3-S 대조에서 조정)·Subscription 시그니처 변경 금지(양측 가정 기준).

## 5. Phase 2 문서 현행화 (승인 후 직렬 1회)

PRD v2.7: 14장 W4 확정 블록(Subscription·subscription_events·AdminUser·AuditLog 스키마·F8 v1.0 최소형
범위[실결제 SIMULATED·수동 결제]·F7 PDF 후속·OTP 방식)·11장 파일럿 무료 운영 주석 보강. 02_prd_update.md.

## 6. Rule ID

F7: INV/PAY/CR 표시 정합(기존)·SUB-001(f8)·SUB-002/003/004(상태·알림)·ADM-001/002(admin 핵심)·
TEN-001/003(admin 마스킹·검색)·MSG(이중 전달 표시는 알림 SIMULATED 기록)

## 7. 리스크

1. Subscription 가정 불일치(f8↔admin) — §2 고정+3-S 대조(F4/F9 성공 패턴 재사용)
2. 관리자 배치 분량 과대(A0+A1+A2+A3) — 조회 중심 MVP로 축소: A1 지표 중 추이 그래프는 숫자 표로
   대체(차트 라이브러리 없음·후续), A2 데이터 내보내기는 후속, A3 환불은 정책 분기 표시+기록(실 환불
   이체는 외부) — 플랜에 명시된 축소만
3. OTP 구현 오류 — 로그인 잠금 5회·감사 로그와 함께 Reviewer 집중 항목
4. 체험 D-7 Recurring 잡 — recurring.yml 공유(3-S)·SIMULATED
