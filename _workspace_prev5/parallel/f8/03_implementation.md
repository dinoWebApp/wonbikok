# 03_implementation.md — f8 구독·결제 v1.0 최소형 (W4 병렬 배치 Phase 3-P)

- 작성: 2026-11-18 / wonbikok-developer (f8 태스크)
- 대상: PRD 7장 F8(v1.0 최소형)·11장·14장 W4 확정 블록·22장 SUB-001~005 / 01_plan §2 시그니처 고정 준수

## 1. 파일 목록

**신규 16건**

| 파일 | 내용 |
|---|---|
| `app/models/subscription.rb` | 시그니처 §2 고정값 그대로. PLAN_LIMITS{light:30, standard:70}·TRIAL_DAYS=30·plan/status enum(validate)·`trial_remain_days`·`trial_expiring?(within: 7.days)`·`students_limit_reached?(current_count)`·`effective_plan`(trial=standard 개방)·`pending_downgrade`(장부 최신 이벤트 판정)·`trial_expiring` 스코프(D-7 잡 진입점) |
| `app/models/subscription_event.rb` | event_type enum 8종(validate)·amount ≥0·`detail_hash`(JSON 파싱 실패 → {})·`operated_by=` TEN-003 마스킹(Payment#confirmed_by= 동일 패턴) |
| `app/services/subscriptions/trial_service.rb` | `start_for!(tenant)` — 30일 체험 자동 생성(standard 개방)·멱등 skip·RecordNotUnique 흡수(레이스 방어) |
| `app/services/subscriptions/plan_change_service.rb` | `change!` 상향 즉시(기간 유지)·하향 pending 이벤트(익월=current_period_end)·`apply_pending_downgrade_for!(force:)`(결제 갱신 경계)·`apply_due_downgrades!`(기간 경과 배치 진입점)·사유 공백·미지의 플랜·동일 플랜 거절(ADM-001) |
| `app/services/subscriptions/payment_service.rb` | `record_manual!` — trial/past_due/suspended → active 전이·기간 1개월 연장([period_end, now].max 기반 — 조기 납부 손실 방지)·cancelled 거절·갱신 시 pending 하향 확정 |
| `app/services/subscriptions/retry_policy_service.rb` | `record_failure!`(payment_failed+retry 예약 D+1/D+3/D+5·3회 past_due)·`suspend!`(past_due→suspended, SUB-002)·`expire_due_trials!`(체험 만료→past_due, SUB-003 진입·배치용)·`data_retention_deadline`·`remaining_retention_days`(카운트다운 계산만)·`failure_count`(결제 성공 시 리셋) |
| `app/services/portone/billing_service.rb` | **SIMULATED** 어댑터 — `configured?`(credentials portone 키)·`simulated?`(키 미등록 또는 PORTONE_LIVE≠1 이중 게이트)·`issue_billing_key`/`request_payment`는 외부 호출 0 시뮬레이션·실호출 자리는 NotImplementedError(P1 REST v2 스파이크 선행 — 바로빌 패턴 준용) |
| `app/controllers/subscriptions_controller.rb` | 단일 리소스 show. TEN-001(tenant 스코프)·레거시(구독 없음)는 empty 렌더 |
| `app/views/subscriptions/show.html.erb` | 플랜·상태 배지·체험 잔여일(D-7 경고색)·기간·원생 수 상한(진행 바+도달 배지)·이력 최근 20건·past_due/suspended 배너(SUB-002/003/004 앱 배너 축)·플랜 변경·수동 결제 안내(v1.0 실행은 A2/A3) |
| `app/views/subscriptions/empty.html.erb` | 빈 상태 + 대시보드 CTA(PRD 15.4) |
| `test/models/subscription_test.rb` | 모델·SubscriptionEvent(아래 매핑) |
| `test/services/subscriptions/trial_service_test.rb` | 4건 |
| `test/services/subscriptions/plan_change_service_test.rb` | 8건 |
| `test/services/subscriptions/payment_service_test.rb` | 7건 |
| `test/services/subscriptions/retry_policy_service_test.rb` | 9건 |
| `test/services/subscriptions/portone_billing_service_test.rb` | 5건(네트워크 스파이 — Net::HTTP.new 접촉 시 예외) |
| `test/controllers/subscriptions_controller_test.rb` | 6건 |

**수정 4건 (가드·훅만 최소 변경)**

- `app/controllers/students_controller.rb` — create 최상단 SUB-001 가드(422 재렌더·Turbo 준수)+`students_limit_reached?` 프라이빗 판정(구독 부재=레거시 통과). 헤더 코멘트 갱신(W4 구현 예정 문구 제거)
- `app/controllers/registrations_controller.rb` — 가입 트랜잭션 안에서 `Subscriptions::TrialService.start_for!` 훅. **rescue 내부에서 흡수 → 가입은 절대 차단되지 않음**(로그만)
- `test/controllers/students_controller_test.rb` — SUB-001 3건 보강(차단·휴원 제외·레거시 통과)
- `test/controllers/registrations_controller_test.rb` — F8 2건 보강(가입 시 체험 생성+이벤트·서비스 장애 시에도 가입 성공)

기존 students/registrations 회귀: setup이 구독을 만들지 않으므로(레거시 경로) 기존 테스트 전부 무영향.

## 2. Subscription 상태 전이표 (전부 도메인 서비스 경유 — 컨트롤러는 표시만)

| 현재 상태 | 트리거 | 다음 상태 | 기록 이벤트 | 수행자 |
|---|---|---|---|---|
| (없음) | 가입(Registrations) | trial | trial_started | TrialService |
| trial | 수동 결제 | active (기간+1개월) | manual_payment | PaymentService(A3) |
| trial | 체험 만료 & 미결제 | past_due | past_due(reason: trial_expired) | RetryPolicyService.`expire_due_trials!` — 3-S recurring 진입점 |
| trial | 플랜 변경 | (plan 즉시 변경, 상태 불변) | plan_changed(applied) | PlanChangeService |
| active | 결제 실패 1~2회 | active 유지 | payment_failed + retry(예약) | RetryPolicyService |
| active | 결제 실패 3회 | **past_due** | payment_failed(소진) + past_due | RetryPolicyService |
| past_due | 결제 실패 4회+ | past_due 유지 | payment_failed 기록만(재시도 예약 없음 — MSG-003) | RetryPolicyService |
| past_due | 수동 결제 | active | manual_payment | PaymentService |
| past_due | suspend! | **suspended** | suspended | RetryPolicyService(A2 조치·recurring 후보) |
| suspended | 수동 결제 | active(재개) | manual_payment | PaymentService |
| cancelled | 수동 결제 | 거절(422) | — | PaymentService |
| any(active 이상) | 플랜 상향 | plan 즉시 | plan_changed(applied, upgrade) | PlanChangeService |
| any(기간 보유) | 플랜 하향 | plan 유지 | plan_changed(pending, effective_on=period_end) → 갱신/경과 시 applied | PlanChangeService |

`data_retention_deadline` = 최근 past_due 이벤트 시점 + 30일(SUB-003 카운트다운 계산만 — 삭제 배치는 후속).

## 3. SubscriptionEvent 타입 (8종 — 01_plan §2·PRD 14장 그대로)

`trial_started / manual_payment / payment_failed / retry / past_due / suspended / plan_changed / refund`

- detail은 **JSON 문자열로 통일**(A2 타임라인·A3 결제 이력이 같은 테이블을 읽음): 예 manual_payment `{method, memo, previous_status, period_start, period_end}`·payment_failed `{attempt, failed_at, next_retry_on, retries_exhausted}`·plan_changed `{direction, from, to, reason, effective_on, status: pending|applied}`
- amount: 결제 계열만 셋팅. operated_by는 TEN-003 마스킹 저장(원장 전화 → `010-****-xxxx`)
- 생성은 도메인 서비스만 가능하도록 컨트롤러·뷰에서 미사용(관례 강제)

## 4. ko.yml 필요 키 목록 (3-S 병합용 — 병렬 태스크 미추가, f4/f9 패턴)

```yaml
subscriptions:
  show:
    title: 구독 관리
    subtitle: "플랜·체험·결제 상태와 이력을 확인합니다."
    plan_label: 현재 플랜
    status_label: 구독 상태
    trial_badge: 무료체험
    trial_ends_at_label: 체험 종료일
    trial_remain_days: "잔여 %{count}일"
    trial_expired: 체험 기한 경과
    period_label: 결제 주기
    cancel_scheduled_label: 해지 예약
    cancel_scheduled_value: "%{date} 예정"
    pending_plan_label: 적용 예정 플랜
    pending_plan_effective: "%{date}부터 적용"
    students_limit_title: 원생 수 상한
    students_limit_full: 상한 도달
    students_limit_full_notice: "상한에 도달했습니다. 새 원생 등록은 차단되며 기존 원생 데이터는 그대로 유지됩니다."
    students_limit_near_notice: "상한이 가깝습니다. 원생이 더 늘어날 예정이라면 플랜 상향을 검토해 주세요."
    students_unit: 명
    events_title: 결제·구독 이력
    events_empty: "아직 기록된 이력이 없습니다."
    operated_by: "처리자 %{operator}"
    won: 원
    past_due_banner: "결제가 완료되지 않아 유예 상태입니다."
    retention_notice: "데이터는 %{deadline}까지 보관됩니다(잔여 %{remaining}일). 기간 내 결제하면 바로 계속 사용할 수 있습니다."
    suspended_banner: "서비스가 일시 정지되었습니다."
    suspended_notice: "원생·청구 데이터는 안전하게 보관되며 조회만 가능합니다. 결제 후 즉시 재개됩니다."
    plan_change_title: 플랜 변경 안내
    plan_change_notice: "플랜 변경은 운영 관리자를 통해 처리됩니다. 원비콕 고객지원으로 요청해 주세요."
    plan_upgrade_notice: "상향: 요청 즉시 적용되며 결제 주기는 그대로 유지됩니다."
    plan_downgrade_notice: "하향: 현재 결제 기간이 끝나는 다음 달부터 적용됩니다."
    manual_payment_title: 결제 등록 안내
    manual_payment_notice: "무통장 입금 등 수동 결제는 운영 관리자가 확인 후 등록합니다. 등록 즉시 이용 기간이 1개월 연장됩니다."
  status: { trial: 무료체험, active: 이용 중, past_due: 결제 유예, suspended: 일시정지, cancelled: 해지 }
  plan: { light: 라이트, standard: 스탠다드 }
  events:
    trial_started: 체험 시작
    manual_payment: 수동 결제
    payment_failed: 결제 실패
    retry: 재시도 예약
    past_due: 결제 유예 전환
    suspended: 일시정지
    plan_changed: 플랜 변경
    refund: 환불
  empty:
    title: 구독 정보가 없습니다
    description: "구독은 가입 시 자동 생성됩니다. 계정에 문제가 있다면 고객지원으로 문의해 주세요."
    cta: 대시보드로 이동
students:
  errors:
    plan_limit_reached: "재원 원생 %{current_count}명이 플랜 상한 %{limit}명에 도달했습니다. 새 원생 등록이 차단되며, 기존 원생 데이터는 그대로 유지됩니다."
activerecord:
  errors:
    models:
      subscription:
        attributes:
          status:
            manual_payment_not_accepted: "해지된 구독에는 결제를 등록할 수 없습니다."
          amount:
            payment_amount_invalid: "결제 금액은 1원 이상이어야 합니다."
          base:
            payment_method_blank: "결제 수단을 입력해 주세요."
            plan_unknown: "알 수 없는 플랜입니다."
            plan_unchanged: "현재와 동일한 플랜입니다."
            plan_change_reason_blank: "플랜 변경 사유를 입력해 주세요(필수)."
```

(기존 `students:` 블록에는 `errors:` 하위 추가 필요 — 최상위 students.errors 신설 여부는 3-S 병합 시 확인)

## 5. 3-S 전달 사항 (공유 파일 결선 요청)

1. **마이그레이션 스펙(1회 통합에 포함)**
   - `subscriptions`: tenant_id(int, null:false, **유니크 인덱스 + FK**)·plan(string, null:false, default "standard")·status(string, null:false, default "trial")·trial_started_at/trial_ends_at/current_period_start/current_period_end/cancel_scheduled_at(datetime, nullable)·timestamps
   - `subscription_events`: subscription_id(int, null:false, FK+인덱스)·event_type(string, null:false)·amount(int, nullable)·detail(text)·operated_by(string)·**created_at만**(append-only 장부 — updated_at 없음. AR은 컬럼 부재 시 자동 skip 확인)
2. **routes**: `resource :subscription, only: :show` (단수 리소스 → `SubscriptionsController`, `subscription_path`) — 컨트롤러·테스트가 이 라우트 기준 작성됨
3. **Tenant 모델**: `has_one :subscription` 추가(f8 모델은 belongs_to만 보유, 테스트는 has_one 비의존으로 작성)
4. **recurring.yml**:
   - 체험 D-7 알림 잡: 조회는 `Subscription.trial_expiring`(기본 7.days) → 솔라피 발송은 Notifications::Dispatcher 경유 SIMULATED 기록(MSG-001 유일성은 message_logs 기준 유지 — SubscriptionEvent는 발송 이력 아님)
   - 체험 만료 배치: `Subscriptions::RetryPolicyService.expire_due_trials!` (매일 1회)
   - 하향 확정 배치: `Subscriptions::PlanChangeService.apply_due_downgrades!` (매일 1회)
   - (후보·정책 합의 필요) past_due 유예 만료 → `suspend!` 자동 전이
5. **레이아웃 네비**: "구독" 진입 → `subscription_path`
6. **admin 태스크 대조**: 시그니처 §2 고정값 그대로 구현 — cancel_scheduled_at은 컬럼 존재·뷰 표시만 지원(설정 경로는 A2/후속), refund 이벤트 타입은 정의만(A3가 생성). A2 체험 연장(30/60일 상한)은 trial_ends_at 연장으로 가능(TrialService 재호출 아님 — 별도 연장 로직은 admin 측 구현 가정)

## 6. 해석 결정 사항 (Reviewer 확인 포인트 — 임의 해석 명시)

1. **SUB-001 집계 기준 = 재원(active) 원생**: 휴원·퇴원은 청구 대상 외(INV-004)이므로 상한 미산정. 컨트롤러에서 `students.active.count` 집계 후 모델에 전달(TEN-001)
2. **체험 중 플랜 변경 = 상하향 모두 즉시 적용**: 체험은 기간 개념이 없고 PRD 11.2 "만료 시 선택"과 정합
3. **suspended에서 수동 결제 = 재활성화 허용**: 막으면 원장 스스로 회복 불가(dead-end) — cancelled만 거절
4. **3회 실패 → past_due, suspended는 명시적 suspend!**: SUB-002 "3회 재시도 후 일시정지"의 자동 정지 주체(배치/관리자)는 P1 결제 잡과 함께 정책 확정 필요 — 상태 프레임만 제공(5번 항목 후보로 3-S 전달)
5. **하향 pending을 컬럼 없이 이벤트 장부로 관리**: 시그니처 고정(§2) 준수 — 최신 plan_changed 이벤트 1개로 pending/applied 판정(`Subscription#pending_downgrade`)
6. **record_failure!는 active·past_due만 허용**: trial(청구 없음)·suspended·cancelled의 실패 기록은 무의미 — 거절
7. **SUB-004 통지**: 앱 배너 축만 본 배치 구현(show 화면 past_due/suspended 배너) — 알림톡 통지는 위 recurring 잡(3-S)에서 SIMULATED 기록으로 이중 전달 충족 예정

## 7. 테스트 매핑 (Rule ID ↔ 테스트 — 총 42건 작성)

| Rule/요구 | 테스트 |
|---|---|
| SUB-001 상한 판정 | subscription_test: light 30/standard 70 경계·effective_plan(trial=standard) 3건 |
| SUB-001 컨트롤러 가드 | students_controller_test: 30명 도달 422 차단+기존 유지·휴원 집계 제외·레거시 통과 3건 |
| 체험 자동 시작·멱등 | trial_service_test 4건·registrations_controller_test 2건(가입 통합·장애 무차단) |
| 체험 잔여일·D-7 | subscription_test: remain/음수/nil·expiring?(7/8/0/경과/비체험)·trial_expiring 스코프 4건 |
| SUB-002 재시도·정지 | retry_policy_test: D+1/D+3/D+5 스케줄·3회 past_due·4회 기록만(MSG-003)·suspend! 허용/재정지 거절·거절 상태 4건 |
| SUB-003 보관 카운트다운 | retry_policy_test: deadline+30·remaining(30/1/0/-1)·expire_due_trials!(만료 전이·결제 구독 보호) 2건 + 컨트롤러 배너 표시 1건 |
| 수동 결제 | payment_service_test 7건(trial/active 조기/past_due/suspended 전이·cancelled 거절·금액/수단 검증·하향 병합 확정) |
| 플랜 변경 | plan_change_service_test 8건(상향 즉시·하향 pending/force/경과 배치·체험 중·사유·플랜 검증) |
| Portone SIMULATED | portone_billing_service_test 5건 — **네트워크 스파이**(Net::HTTP.new 접촉 시 예외 주입)로 외부 호출 0 보장 |
| TEN-001 | subscription_test(테넌트 필수·1:1 유니크)·subscriptions_controller_test(타 테넌트 수치 미노출) |
| TEN-003 | subscription_test(operated_by 마스킹)·subscriptions_controller_test(마스킹 표시) |
| Turbo·검증 | students 가드 422 재렌더·가입 303 유지(기존 테스트 회귀 없음) |

주의: **컨트롤러 뷰 단정은 DB 파생 텍스트(수치·일자·마스킹)만** — subscriptions.* i18n 키는 3-S 병합 대상이라 단정에서 제외(f4/f9 패턴 준용, 병합 후 수정 불요). 라우트·마이그레이션은 3-S 결선 후 컨트롤러·모델 테스트가 함께 기동된다(01_plan fan-out 제약).

## 8. 실행 검증 결과 (자기 범위)

- `bin/rubocop` 자기 19파일 — **0 offenses**
- 스크래치 DB(/tmp SQLite, 마이그레이션 파일 생성 없음·dev DB 비접촉)에서 **모델·서비스 상태 전이 15건 전부 통과**: 체험 생성/멱등·SUB-001 경계·D-7 판정/스코프·상향 즉시·하향 pending→갱신 확정·사유 거절·결제 4상태 전이+1개월 연장·재시도 스케줄/3회 past_due/4회 기록만·suspend!·보관 카운트다운·카운터 리셋·Portone SIMULATED(네트워크 0)·detail 방어·expire_due_trials!
- 뷰 렌더 검증(layout 제외): show(trial·past_due 배너·이력·마스킹·금액)·empty 전부 통과
- `Rails.application.eager_load!` — zeitwerk 정상, SubscriptionsController·Portone::BillingService·Subscriptions::* 전부 로드

## 9. 후속 과제 (본 배치 범위 외 — 기록)

- 정기결제 실호출(포트원 REST v2 스파이크 → BillingService real 구현) — P1
- 결제 재시도 실제 청구 잡·suspended 자동 전이 정책·데이터 삭제 배치(SUB-003 이행)
- 플랜 변경 원장 요청 버튼(이벤트 기록 [요청])·구독 진입 네비·Tenant has_one — 3-S
