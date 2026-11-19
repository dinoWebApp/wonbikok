# 03_implementation.md — F10 영업 직원·오피서 추천 시스템 구현

- 작성일: 2026-11-19
- 담당: wonbikok-developer (Phase 3 — 일반 모드 직렬)
- 기준: `_workspace/01_plan.md` 확정 플랜 + PRD v2.8 (7장 F10·22장 REF-001~007·14장 F10 확정 블록)

## 1. 완료 요약

- 마이그레이션 1개(테이블 4종 + tenants 확장)·모델 4종(+Tenant/AuditLog 확장)·서비스 4종·잡 1종·
  컨트롤러 5종(가입 확장 포함)·뷰 9종(+admin 사이드바)·Stimulus 1종·라우팅·ko.yml·seeds 완료.
- **품질 게이트**: `bin/rails db:migrate` 성공 / `bin/rubocop` 0 에러(198 files) /
  `bin/brakeman` 0 경고 / `bin/rails test` **588 runs 0 failures** (기존 490 + 신규 98, 목표 540+ 초과).

## 2. 생성·수정 파일

### 신규
| 파일 | 내용 |
|---|---|
| `db/migrate/20261119000001_create_referral_system_tables.rb` | sales_reps·referral_codes·signup_verifications·commission_ledgers + tenants 3컬럼(referred_by_sales_rep_id·referral_code_snapshot·first_payment_discounted_at) |
| `app/models/sales_rep.rb` | role(sales/officer) string 검증·effective_commission_rate/cap_months(role 기본 0.20/12·0.15/nil)·suspend!(사유 필수+코드 즉시 무효화)·active_referral_code·5회 잠금 |
| `app/models/referral_code.rb` | live 스코프(교체 전+만료 전)·active? — 이력 보존(replaced_at, 삭제 금지) |
| `app/models/signup_verification.rb` | phone deterministic 암호화(TEN-003)·attempts 5회·usable_for_signup?(verified+미소비+미만료) |
| `app/models/commission_ledger.rb` | status pending/paid enum·month YYYY-MM 검증·paid→paid_at 필수 |
| `app/services/referral/code_service.rb` | issue_for!(교체 발급)·verify!(유효→rep/외 nil)·rotate_all!(활성 전원) |
| `app/services/referral/discount_service.rb` | apply_first_payment! — 20%·DB 원자 갱신 멱등(`WHERE first_payment_discounted_at IS NULL` UPDATE 행수) |
| `app/services/referral/commission_service.rb` | accrue_on_payment!(캡 판정+스냅샷)·monthly_summary·expected_this_month(전월)·yearly_summary·mark_paid!(사유+감사)·monthly_charged_totals |
| `app/services/signup/phone_verification_service.rb` | send_code!(정규화·1분 리밋·미소비 무효화·bcrypt 저장·솔라피 SIMULATED)·verify!(만료·5회·불일치)·consume!(원자 소비) |
| `app/services/sales/dashboard_service.rb` | REF-005 스코프 집계 단일 경유(코드·피판매 rows·월별 결제액·수령 예상·연 누적) |
| `app/jobs/referral_code_rotation_job.rb` | 주간 로테이션 배치(발송 없음) |
| `app/controllers/sales/base_controller.rb` | 제3 인증 체계(sales_rep_id 세션)·active rep만 세션 유효(정지 즉시 차단) |
| `app/controllers/sales/sessions_controller.rb` | 이메일+비밀번호·5회 잠금·정지 차단·rate_limit 10/3분·reset_session |
| `app/controllers/sales/dashboards_controller.rb` | 대시보드(연도 클램프) — 서비스 경유만 |
| `app/controllers/admin/sales_staffs_controller.rb` | CRUD·suspend/resume(사유)·mark_paid(사유) — 뷰 쿼리 없음 |
| `app/views/layouts/sales.html.erb` | 웜 오렌지·직함 헤더·데스크톱/모바일 겸용 |
| `app/views/sales/sessions/new.html.erb`·`sales/dashboards/show.html.erb` | 로그인·대시보드 5블록(clipboard 재사용) |
| `app/views/admin/sales_staffs/{index,_form,new,edit,show}.html.erb` | 관리자 화면(정지·지급 확정 폼 포함) |
| `app/javascript/controllers/signup_verification_controller.js` | 인증 단계 UI(fetch·문구는 뷰에서 ko.yml 주입) |
| `test/…` 12개 파일 | models 4·services 5·jobs 1·controllers 2(sales 통합 1파일)·integration(E2E) + 기존 2파일 갱신 |

### 수정
- `app/models/tenant.rb` — belongs_to :referred_by_sales_rep(optional)·`referred?`
- `app/models/audit_log.rb` — AUDIT_ACTIONS_REQUIRING_REASON에 sales_rep_suspended/resumed·commission_paid 추가
- `app/services/subscriptions/payment_service.rb` — F10 확장(아래 §3)
- `app/controllers/registrations_controller.rb` — 인증·추천 코드 확장(아래 §4)
- `app/views/registrations/new.html.erb` — 인증 단계·추천 코드 필드
- `app/views/layouts/admin.html.erb` — 사이드바 "영업 직원" 활성 항목
- `config/routes.rb` — registration send_verification/verify·admin sales_staffs(member suspend/resume/mark_paid)·sales namespace
- `config/recurring.yml` — referral_code_rotation(월요일 09:00 "0 9 * * 1")
- `config/locales/ko.yml` — signup_verification·registration.verification·admin.sales_staffs·admin.nav.sales_staffs·sales 전체
- `db/seeds.rb` — sales/officer 샘플(ENV: SALES_EMAIL/PASSWORD·OFFICER_EMAIL/PASSWORD) + 첫 코드 발급
- `test/test_helper.rb` — verify_signup_phone!·with_fixed_verification_code 헬퍼
- `test/controllers/registrations_controller_test.rb` — 기존 5건 갱신(검증 레코드 사전 생성) + F10 10건 추가

## 3. PaymentService 확장 (할인·수수료 원자적)

`record_manual!` 트랜잭션 내 순서: 플랜 하향 확정 → 기간 산정 → **DiscountService.apply_first_payment!**
(피추천·첫 결제만 — 징수액=할인 후) → 이벤트 생성(detail에 `original_amount`·`discount_applied`·
`discount_amount` 기록 — SUB-005 정합) → **CommissionService.accrue_on_payment!**(할인 후 실제 징수액
기준·결제 시점 요율 스냅샷·source_subscription_event_id 연결).

- **할인·수수료 실패는 결제 성공을 롤백하지 않는다**(PAY-004 패턴 준용): 각 단계 rescue → 로그만.
  할인 실패 시 정상가 폴백, 수수료 실패 시 ledger 미생성(테스트로 고정).
- 비추천 테넌트는 기존 동작 그대로(기존 8건 테스트 무수정 통과 — 회귀 방어 테스트 추가).

## 4. 가입 플로우 확장 (REF-006 서버 원천)

- 인증 상태의 **원천은 DB(signup_verifications)** — 세션 의존 없음. UI(Stimulus fetch)는 표현·편의만.
- `create` 서버 검증: 제출 전화 = verified·미소비·미만료 레코드의 전화 + **소비(consume!) 필수**,
  미충족 시 가입 트랜잭션 롤백(VerificationMissingError) + 422. 소비는 트랜잭션 내부 — 가입 실패 시 소비도 롤백.
- `consume!`은 `update_all(... WHERE consumed_at IS NULL)` 원자 갱신 — 동시 가입 레이스에서 1회만 소비.
- 추천 코드: `verify!` 유효 시 tenants 매핑·`referral_code_snapshot` 저장(가입 시점 스냅샷 — 이후
  로테이션 무영향). 무효 코드 입력 시 422 안내. 기존 휴대폰 유니크 회귀 유지(RecordNotUnique 안내 포함).
- rate_limit 10회/3분(컨트롤러) + 서비스 레벨 1분 1회(번호별) 이중 방어.

## 5. 설계 결정 (Reviewer 집중 요청)

1. **[중요] 인증번호 발송의 동기 처리** — 솔라피 호출을 Job으로 넘기면 일회성 코드 원문이 Solid Queue
   잡 인자로 **DB에 저장**되어 REF-006 "평문 저장 금지(code_digest)" 원칙과 충돌한다. 또한 bcrypt는
   복원 불가해 잡이 코드를 재구성할 수도 없다. 그래서 `Signup::PhoneVerificationService`(전용 Service
   객체)에서 동기 발송하며, 키 미설정 시 SIMULATED 로그, 코드 로그는 `Rails.env.local?` 한정.
   *AGENTS "외부 API는 Active Job 경유만"의 예외이며, 이유는 코드 원문 비-저장 우선.
   카카오 인증 템플릿 심사 후 재검토 권장(예: 암호화 잡 인자 도입 시).
2. **판매 캡 판정 기준** — `tenants.created_at`(가입일) 기준, `결제시각 <= 가입일+cap개월` 경계일 포함
   (12개월째 결제 포함, 13개월째 제외 — 테스트로 고정).
3. **수수료 발생과 정지 무관** — REF-007은 코드 무효화·접근 차단만 규정하므로, 정지 직원의 기발생
   캡 내 결제분 ledger는 계속 축적(집계·지급 확정 가능). 로테이션 잡도 정지 직원 제외.
4. **expected_this_month 산식** — "이번달 수령 예상 = 전월 ledger 합계(지급/미지급 무관)".
   월 단위 후불 문구와 일치시켰다(화면 산식 병기 — A1 관행 준용).
5. **환불 차감(ledger 역분)은 v1.0 미구현** — A3 refund가 "기록만"인 현 정합(v1.0)에 맞춰 후속 과제로
   명시(§7). REF-003 집계는 실제 징수액 기준이므로 refund 이벤트 실이체 전환 시 역분 필요.
6. **SignupVerification 만료 후 가입 불가** — verified라도 레코드 만료(5분) 경과 시 consume 불가
   (usable_for_signup?). 안전 우선(검증 의도는 단기 유효) — UX상 재인증 1회 부담.
7. **직원 email 마스킹 불가 처리** — 업무 연락처로 ADM-002 대상 외(과업 지시). 피판매 목록은
   상호만 노출(원장 개인정보 자체를 조회·전달하지 않는 구조적 마스킹).
8. **Sales 로그인 reset_session** — Admin 로그인과 동일한 세션 고정 방어. 같은 브라우저의 관리자
   세션은 초기화된다(테스트로 문서화 — 별도 브라우저 사용 전제).
9. **tenants.referred_by_sales_rep_id는 FK 없이 인덱스만** — 직원 계정은 삭제가 아닌 정지가 유일
   생명주기 조치라 파괴 경로가 없으나, tenants 쪽 의존 제약으로 원생 데이터를 보호하기 위함.

## 6. REF 테스트 매핑

| Rule | 강제 수단 | 테스트 |
|---|---|---|
| REF-001 | CodeService(8자 SecureRandom·7일·교체 발급)·ReferralCode.live·가입 422 | code_service 6·referral_code 4·registrations 3(만료·무효·정규화) |
| REF-002 | DiscountService 원자 갱신(first_payment_discounted_at) | discount 6(경쟁 5동시 호출 포함)·payment F10 5·E2E |
| REF-003 | CommissionService within_cap?(가입일 기준·경계 포함)·징수액 기준 | commission 11(sales 캡 경계·officer 무기한·캡 조정)·payment F10 |
| REF-004 | ledger 스냅샷(base/rate/amount 결제 시점) | commission 스냅샷 불변·신규 신요율 |
| REF-005 | Sales::BaseController(active rep만)·DashboardService 단일 경로 | dashboard_service 4·sales controllers 9(타직원 404 아닌 미노출·정지 세션 차단) |
| REF-006 | PhoneVerificationService(bcrypt·5회·1분 리밋·원자 소비) + create 서버 검증 | phone_verification 11·registrations 10(미검증 422·전화 불일치·429 등) |
| REF-007 | SalesRep#suspend!(사유 필수+코드 무효화)·Sales 세션 차단·AuditLog 사유 필수 | sales_rep 10·code_service·sales sessions·admin sales_staffs 10·E2E |

추가: 관리자 CRUD·role 기본값·요율 범위·지급 확정(사유·audit·멱등) 10건, 로테이션 잡 3건,
E2E 체인 3건(인증→코드→가입→할인→ledger→대시보드 / 로테이션 무영향 / 정지 코드 가입 거절).

## 7. 후속 과제 (운영·P1)

1. 카카오 인증 템플릿 심사(별도 템플릿 유형 `signup_verification`) — 심사 통과 전 SIMULATED.
   도입 시 인증번호 발송 경로의 Job 래핑 재검토(§5-1).
2. 환불 시 commission_ledgers 역분(REF-003 "실제 징수액" 정합 — refund 실이체 전환 시 필수).
3. F8 P1 포트원 정기결제 전환 시 할인·수수료 규칙을 BillingService로 이관(동일 규칙).
4. 월요일 09:00 로테이션 실패 시 Solid Queue 재시도 의존 — 운영 알림 연동(ADM) 여부 결정.
5. 피판매 목록 100건 상한(DASHBOARD_TENANT_LIMIT) — 초과 직원 페이징은 후속.

## 8. 자체 체크리스트

- [x] Rule ID 무결성 — 유니크 인덱스(code·email)·consume 원자 갱신·mark_paid 멱등·ledger 스냅샷
- [x] TEN-003 — signup_verifications.phone deterministic 암호화, SMS 발송 시 복호화 경유만
- [x] TEN-001/REF-005 — Sales 조회 전부 본인 rep 스코프(컨트롤러 파라미터에 rep id 없음)
- [x] ADM-001 — 정지/해제/지급 확정 사유 필수(AuditLog 2차 방어 포함)·감사 로그 기록
- [x] 외부 API — Solapi::Client 재사용·SIMULATED 분기·실호출 테스트 금지
- [x] Turbo 규약 — 실패 422(render :new/:show)/성공 303(see_other)
- [x] i18n — 신규 문구 전부 ko.yml(뷰·JS 하드코딩 없음 — JS 문구는 뷰에서 data 주입)
- [x] 뷰 쿼리 금지 — 집계는 서비스/컨트롤러 private, 뷰는 @변수만
- [x] 2칸 스페이스·RuboCop 0·Brakeman 0·테스트 588건 통과

## 9. Phase 5 리뷰 수정 (1차 → 2차, 2026-11-19)

05_review.md 지적 최소 수정 — **B-1 1건 + W-1~W-4 4건**(W-5는 기존 문서화 유지):

| 항목 | 수정 내용 |
|---|---|
| B-1 (BLOCKER) | `sales/sessions/new.html.erb` — `form_with scope: :sales_session` 추가(필드 name 계약 복원) + 재발 방지 통합 테스트 1건(렌더 HTML `sales_session[email]`·`[password]` 단정 + 실제 POST 로그인 성공) |
| W-1 | `Signup::PhoneVerificationService#send_code!` — `deliver!`를 transaction 블록 밖(create! 커밋 후)으로 이동. 발송 실패 rescue 흡수는 기존 동일 |
| W-2 | `Admin::SalesStaffsController#prepare_commission_summary`에 `@referred_tenants` 조립 이관 — show 뷰 쿼리 제거 |
| W-3 | `Sales::DashboardService#tenant_rows` — `includes(:subscription)` 프리로드(N+1 해소) |
| W-4 | `SalesRep` — referral_codes·commission_ledgers `dependent: :restrict_with_exception` + 검증 테스트 1건(이력 보존·삭제 차단) |

- 게이트 재검증: rubocop 0(198 files)·brakeman 0·`bin/rails test` **590 runs 0 failures**(588 + 신규 2)
- 영향 파일: app/views/sales/sessions/new.html.erb·app/services/signup/phone_verification_service.rb·
  app/models/sales_rep.rb·app/services/sales/dashboard_service.rb·app/controllers/admin/sales_staffs_controller.rb·
  app/views/admin/sales_staffs/show.html.erb·test 2파일(추가 테스트 2건)
