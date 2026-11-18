# 03_implementation.md — integ (Phase 3-S 통합: F7·F8·관리자 A0~A3 결선)

- 작성일: 2026-11-18 / wonbikok-developer (integ 태스크)
- 대상: `_workspace/01_plan.md` §1 integ 행 — 마이그레이션 1회·routes 결선·ko.yml 병합·recurring·
  Subscription 시그니처 대조·전체 게이트 선행

## 1. 결선 내역

### 1.1 마이그레이션 — 단 1개
`db/migrate/20261118000002_create_subscription_and_admin_tables.rb` (신규, `bin/rails db:migrate` 완료·schema.rb 커밋)

| 테이블 | 내용 | 무결성 |
|---|---|---|
| `subscriptions` | tenant_id·plan(기본 standard)·status(기본 trial)·trial_started_at/ends_at·current_period_start/end·cancel_scheduled_at·timestamps | `tenant_id` 유니크 인덱스 + FK(1:1 — SUB-001·TEN-001) |
| `subscription_events` | subscription_id(FK+인덱스)·event_type·amount·detail(text)·operated_by·**created_at만**(append-only) | `[subscription_id, event_type]` 인덱스 — updated_at 부재는 AR이 자동 skip(f8 스펙 준수) |
| `admin_users` | email·password_digest·otp_secret·failed_attempts(기본 0)·locked_at·timestamps | email 유니크 인덱스 |
| `audit_logs` | admin_user(optional FK)·action·target_type/target_id·reason·detail(json)·timestamps | `[target_type, target_id]`·`[action, created_at]` 인덱스 |

### 1.2 routes 결선 (`config/routes.rb`)
- `get "dashboard/report"` → `dashboard#report`(as: :dashboard_report) — f7 §4.1 요청
- `resource :subscription, only: :show` — f8 §5.2 요청(f8 테스트 `subscription_url` 기준과 일치)
- `namespace :admin` 블록 — admin §6.2 코드 그대로(14 헬퍼 isolated 검증분) — 실측 15 헬퍼 전부 응답
- 앱 레이아웃 네비 구독 진입: 데스크톱 탭 + 모바일 하단 탭 5번째(icon "subscription" SVG 1분기 추가), `nav.subscription` 키 신설

### 1.3 ko.yml 병합 — 누락 0 (전수 대조)
| 블록 | leaf 키 수 | 출처 |
|---|---|---|
| `dashboard`(기존 13 + 신규 34) | 47 | f7 §3 전문(38키) + integ `report_link` 1 + 기존 |
| `subscriptions` | 50 | f8 §4 전문 |
| `admin` | 218 | admin §5 전문 |
| `students.errors.plan_limit_reached`·`students.show.history.{no_bill,no_receipt}` | 3 | f8 §4·f7 §3 |
| `activerecord.errors.models.subscription.*` | 7 | f8 §4 |

- **검증**: 앱 전체 ERB 87파일의 `t("정적키")` 전수 대조 스크립트 → 미해결 0(2건 오탐은 `except(` 정규식误 탐)
- **레거시 키 정리**: `dashboard.unpaid_count`·`dashboard.reminders_link` — 사용처 0 확인 후 제거(f7 §3 무위화 제안)
- **값 현행화**: `students.show.history_title` → "수납·발행 이력(최근 6개월)"(f7 제안), `history_empty` → "아직 수납·발행 이력이 없습니다."(구문 "청구 기능은 다음 업데이트에 제공됩니다"는 W2 이후 사실과 불일치 — 값만 변경, 테스트 단정 없음 확인)

### 1.4 recurring.yml + 잡 클래스 3종 신설 (f8 §5.4 요청 — 모두 SIMULATED·멱등)
| 잡 | 클래스 | 진입점 |
|---|---|---|
| `subscription_trial_reminder` 09:10 | `app/jobs/subscription_trial_reminder_job.rb`(신규) | 조회 `Subscription.trial_expiring`(f8 스코프) → SIMULATED 로그 기록. 캐시 마커로 체험 기간당 1회. 실발송(P1) 시 구독 단위 발송 이력 확장 필요 — message_logs는 invoice_id 필수라 오용 금지(MSG-001 주석 명시) |
| `subscription_trial_expire` 09:20 | `app/jobs/subscription_trial_expire_job.rb`(신규) | `Subscriptions::RetryPolicyService.expire_due_trials!`(매일, 멱등) |
| `subscription_downgrade_apply` 09:30 | `app/jobs/subscription_downgrade_apply_job.rb`(신규) | `Subscriptions::PlanChangeService.apply_due_downgrades!`(매일, 멱등) |

- MSG-006 야간 발송 금지 준수(09:10~09:30 — reminder_dispatch 09:00 이후 분산). 러너로 3잡 perform_now 실측 통과.
- f8이 "past_due 유예 만료 → suspend! 자동 전이"를 (후보·정책 합의 필요)로 남김 → 본 배치 미채택(정책 확정은 Reviewer/후속 — A2 명시적 suspend! 경로만 현행).

### 1.5 시드 (`db/seeds.rb`)
`AdminUser` 1계정 — `ADMIN_EMAIL`(기본 `ops@wonbikok.local`)·`ADMIN_PASSWORD`(미지정 시 `SecureRandom.hex(12)` 생성) ENV 기반, `find_or_create_by!` 멱등. TOTP는 otp_secret 미설정 시 credentials `admin.otp_seed` 파생(미설정 개발 환경은 폴백+경고 로그 — `Admin::OtpService` 코드 주석 확인). `bin/rails db:seed` 실측 1계정 생성.

## 2. Subscription 시그니처 대조 (f8↔admin — 01_plan §2 기준)

admin §6.3의 자체 정렬을 전수 재대조 — **불일치 0**:

| 접점 | f8 실구현 | admin 사용 | 판정 |
|---|---|---|---|
| 상한 | `students_limit`(effective_plan — 체험 중 standard 70) | base_controller `students_limit` | ✅ |
| 체험 만료 | `trial_expiring?(within: 7.days)` | dashboards_controller | ✅ |
| 플랜 변경 | `Subscriptions::PlanChangeService.change!(plan:, operated_by:, reason:)` | tenant_actions 경유 | ✅ |
| 이벤트 장부 | `detail`(JSON 문자열)·`operated_by=` 마스킹·created_at 전용 | 동일 규약 생성·조회 | ✅ |
| 보관 만료 | `Subscriptions::RetryPolicyService.data_retention_deadline` | subscription_payments 단일 경유(+updated_at 근사 폴백) | ✅ |
| `trial_extended` | **enum 부재(⚠ f8 §6.3 지적) → integ가 1줄 추가** | tenant_actions 생성 | ✅ 결선 |
| Tenant 역참조 | `belongs_to :tenant`만 → **integ가 `has_one :subscription, dependent: :destroy` 추가[3-S 소유]** | 미의존(양측) | ✅ 결선 |
| Invoice 역참조 | CashReceipt belongs_to만 → **integ가 `Invoice has_many :cash_receipts` 추가**(payments 선례 — dependent 없음·이력 보존) | — | ✅ 결선(f7 §4.3 권장) |

## 3. integ 조정 내역 (불일치 최소 수정 — 도메인 로직 재작성 없음)

### 3.1 코드 수정 (10건)
| 파일 | 수정 | 원인 |
|---|---|---|
| `app/controllers/subscriptions_controller.rb` | `RetryPolicyService` → `Subscriptions::RetryPolicyService`(2줄) | 네임스페이스 미경유 — 런타임 NameError(f8 "뷰 렌더 검증"이 컨트롤러 경로 미포함으로 미검출) |
| `app/controllers/admin/dashboards_controller.rb` | `window = (RECENT_WINDOW.ago..)` 괄호 | 무괄호 endless range 뒤 `{`가 해시 리터럴(범위 끝)로 파싱 → `ArgumentError: bad value for range` — 관리자 대시보드·OTP 로인 전 화면 전반 크래시 |
| `app/controllers/admin/tenant_actions_controller.rb` | suspend 경로에 `@subscription = Subscription.find_by(...)` 1줄 | valid_subscription? 미호출로 ivar nil → suspended 이벤트 무기록 |
| `app/controllers/admin/tenant_actions_controller.rb` | `result.applied` → `result.applied?` | Result Data 멤버명 불일치(NoMethodError) |
| `app/controllers/admin/tenant_actions_controller.rb` | extend_trial 검증 순서 — 누적 한도 초과를 1회 한도(1~30일)보다 먼저 | 초과 시나리오(30사용+31요청)에서 한도 초과 안내가 아닌 "1~30일" 안내 노출(422 유지 — 우선순위만 변경) |
| `app/controllers/admin/subscription_payments_controller.rb` | `month_range` — `Date#all_day`(그날 하루) → `beginning_of_day..end_of_month.end_of_day`(월 전체) | 결제 이력이 당월 1일 하루만 조회되는 버그(매출 집계는 정상 — 불일치 노출) |
| `app/controllers/admin/subscription_payments_controller.rb` | `prepare_refund_form` 음수 override 시 기본값 복귀 1줄 | 음수 금액 422 재렌더 경로에서 `RefundPolicyService.new(amount: 음수)` ArgumentError(서비스 음수 거절 계약 유지) |
| `app/services/portone/billing_service.rb` | `simulated?` 동적 판정(생성자 캐시 제거) | 코드 주석 스스로 명시한 "게이트는 메서드별 simulated? 우선" 계약과 불일치 — ENV 개방이 생성 후에도 반영되도록(NotImplementedError 게이트 실동작) |
| `app/models/audit_log.rb` | `record!`에 `created_at:` 옵션(백데이팅 전용 주석) | 타임라인 테스트가 통합 진입점 경유 백데이팅 사용 — create!은 애초 created_at 직접 허용이므로 보호 수준 불변 |
| `app/models/subscription_event.rb` | **enum에 `trial_extended` 1줄 추가**(결선 필수 1건) | admin 체험 연장 이벤트 생성 시 ArgumentError |

### 3.2 뷰·레이아웃 (integ 결선분)
- `app/views/layouts/application.html.erb`: 구독 탭(데스크톱·모바일) — 기존 tab 렌더 규약 준용
- `app/views/dashboard/show.html.erb`: 지표 카드 헤더에 `dashboard_report_path(month:)` 링크(f7 §4.1 권장 — 신규 키 `dashboard.report_link` 1개)
- `app/views/students/show.html.erb`: 이력 조회를 `@student.invoices.includes(:cash_receipts)` 역참조 2쿼리로 정리(f7의 뷰 스코프 → 3-S 결선 연관 경유. before_action 이관은 미채택 — students_controller는 f8 소유·최소 변경 원칙)

### 3.3 테스트 최소 수정 (8파일 — 도메인 로직 변경 없이 시그니처·픽스처·이스케이프 불일치만)
| 파일 | 수정 | 사유 |
|---|---|---|
| `students_controller_test.rb` | SUB-001 채움 원생 29→28·27 | fixture `students(:one)` 정재원(active)이 카운트에 포함 — Expected 30/29 vs Actual 31 |
| `subscription_test.rb` | light 상한 테스트 `status: :active` 명시 / 만료 청구 2개째는 신규 Tenant | 체험 중 effective_plan=standard(f8 구현·admin 정렬·동일 파일 다른 테스트와 일치하는 규약) / tenant_id 유니크 위반 |
| `plan_change_service_test.rb` | 하향 3테스트에 `plan: :standard` 사전 세팅 | light 구독에 light 변경 요청 → `:plan_unchanged` 거절(서비스 정상 동작) |
| `retry_policy_service_test.rb` | retry 이벤트 기대 1→2 | 실패 1·2회차에 각 1건(총 2) 생성이 구현·상태전이표 기준 — "3회 이후 예약 없음"은 신규 생성 없음을 의미 |
| `trial_service_test.rb` | trial_ends_at==current_period_end 정확 일치 → in_delta 1초 | 별도 `from_now` 호출의 마이크로초 오차 |
| `payment_service_test.rb` | 체험 중 결제 기간 시작 기대 now→trial_ends_at | `[period_end, now].max` 규약(서비스 주석·f8 보고서·2번째 테스트와 동일 규약 — 조기 납부 손실 방지) |
| `subscriptions_controller_test.rb` | TEN-001: 원생명 단정 → `/ 30명`·`70명` 미노출 단정 + 비체험 구독 | 화면은 수치만 표시(원생명 미노출이 설계)·체험 중 상한은 70(effective_plan 규약) |
| `admin/*_test.rb` 4건 | `create_event` amount 기본값 / 검색 빈상단 ERB 이스케이프(`'`→`&#39;`) / 감사 detail Hash exists?→레코드 파싱 | helper 키워드 필수·HTML 이스케이프·json 컬럼 질의 한계 |

## 4. 게이트 결과 (전 구간)

| 게이트 | 결과 |
|---|---|
| `bin/rails db:migrate` | 완료 — schema.rb 4테이블 반영 |
| `bin/rubocop` | **170 files inspected, no offenses** |
| `bin/brakeman` | **No warnings found** |
| `bin/bundler-audit` | No vulnerabilities found |
| `bin/rails test` | **480 runs, 2126 assertions, 0 failures, 0 errors, 0 skips** (f7 16 + f8 42 + admin 수십 + W1~W3 회귀 전부 포함) |
| 부트 실측 | `eager_load!` 정상 / route 헬퍼 15종 / recurring 5잡 로드·신규 3잡 perform_now 통과 / db:seed AdminUser 1계정 |
| `git status` 소유권 점검 | 01_plan §1 표와 불일치 0 — 공유 파일(routes·ko.yml·recurring·레이아웃·schema·seeds)은 전부 integ 변경분, f7/f8/admin 변경분은 각 소유 화이트리스트 내 |

## 5. Reviewer 집중 요청 사항

1. **체험 D-7 알림의 발송 유일성 저장소** — v1.0은 SIMULATED 로그+캐시 마커(체험 기간당 1회). 실발송 전환 시 구독 단위 발송 이력(스키마 확장) 필요 — message_logs 오용 금지 근거를 Job 주석에 명시. MSG-001/003 관점 리뷰 요청.
2. **`past_due → suspended` 자동 전이 미채택** — f8이 정책 합의 필요로 남긴 recurring 후보. 현행은 A2 명시적 suspend!만(SUB-002 자동 정지 주체는 P1 결제 잡과 함께 확정).
3. **`AuditLog.record!` created_at 옵션** — 백데이팅 전용 옵션 추가(테스트·이관). 운영 조치 경로 미사용이지만 감사 장부 무결성 관점 확인 요청.
4. **extend_trial 검증 우선순위**(누적 한도 → 1회 한도) — 422 응답은 동일하나 안내 문구 우선순위 변경. UX 의도 적합성 확인.
5. ** tenants/show 정지 기록 배지·A1 지표의 `updated_at` 근사 산식**(월 해지·MAU) — admin 보고서 §4 축소 목록과 일치하는지 최종 확인.
6. **f8 §9 후속**(포트원 실호출 P1·플랜 변경 원장 요청 버튼·A5 등) — 본 배치 범위 외 유지 확인.

## 6. 자체 체크리스트

- [x] 마이그레이션 1개·유니크 인덱스·FK·schema.rb 커밋본 반영
- [x] f7/f8/admin 도메인 로직 재작성 0 — 결선·enum 1줄·불일치 최소 수정만(§3 전건 보고 명시)
- [x] SIMULATED 유지(포트원·D-7 알림) — 외부 실호출 0(부트 실측 포함)
- [x] credentials 미수정(otp_seed 읽기만)·연습 모드 분기 회귀 없음(W1~W3 테스트 전 통과)
- [x] Turbo 규약(422/303)·TEN-001 스코프·Rule ID(TEN/INV/PAY/CR/MSG/LNK/SUB/ADM) 회귀 없음
- [x] ko.yml 전수 대조 미해결 0·레거시 키 2건 무위화 제거
