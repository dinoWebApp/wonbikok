# 07_test_report.md — F10 추천 시스템 테스트 (Phase 7)

- 실행일: 2026-11-19 · 프로필: wonbikok-tester · 판정: **PASS**
- 범위: 1~2차 리뷰(05_review.md "Tester 제안"·"Tester 권고") 시나리오 보강 + REF-001~007 커버 점검 + 전체 회귀

## 1. 실행 결과 (게이트)

| 게이트 | 결과 |
|---|---|
| `bin/rails test` | **592 runs, 2,672 assertions, 0 failures, 0 errors, 0 skips** (Phase 6 기준 590 → +2 보강) |
| `bin/rubocop` | 198 files inspected, **no offenses** |
| `bin/brakeman` | **No warnings found** |
| 외부 실호출 | 없음 — test env 솔라피 키 공란 → `PhoneVerificationService#simulated?` SIMULATED 분기 확인(config/solapi.yml), F10 테스트에 포트원·바로빌 호출 경로 없음 |

## 2. 보강 내역 (리뷰 권고 2건 — 모두 미커버 확인 후 추가, 테스트만·소스 무수정)

| # | 시나리오 | 파일 | 기존 커버 상태 → 조치 |
|---|---|---|---|
| 1 | **REF-002 결제 트랜잭션 롤백 시 할인 claim 원복 → 재시도 결제에 할인 재적용** — claim(`first_payment_discounted_at` 원자 갱신) 성공 직후 기간 갱신 단계를 1회 한정 실패 유도(인스턴스 싱글턴 `update!` 재정의 — 기존 WARNING-6 테스트 패턴 준용) → 롤백 검증: 결제 실패·claim nil 원복·이벤트/ledger 0건·trial 유지 → 재시도: 8,000원(20% 할인) 재적용·ledger 1건 | `test/services/subscriptions/payment_service_test.rb` | 부재(기존은 "할인 서비스 자체 실패→정상가 폴백"만 커버) → **추가** |
| 2 | **REF-006 검증 완료 직후 TTL 만료 경과 시 가입 거절** — `usable_for_signup?`(verified·미소비·미만료)이 가입 create 통합 경로에서 422 거절로 이어지는지 검증 + 미소비 유지(재인증 후 가입 가능) | `test/controllers/registrations_controller_test.rb` | 부재(모델 `usable_for_signup?`·서비스 `consume!` 만료는 커버, 컨트롤러 create 경로만 공백) → **추가** |

- 2차 리뷰 잔여 권고는 본 2건이 전부(REF-003 캡 경계는 기존 commission_service_test로 충분 판정 — 1차 합의) → 신규 생략 없음.
- 시행 착오 1건(테스트 오류, 코드 버그 아님): `raise ActiveRecord::RecordInvalid, "문자열"`은 record 기반 생성자라 NoMethodError — record 기반 `errors.add` + `RecordInvalid.new(self)`로 수정 후 통과.

## 3. REF-001~007 커버 매핑 (구현 보고서 §6 대조 + 전건 실행 확인)

| Rule | 강제 수단 | 커버 테스트 (전건 통과) |
|---|---|---|
| REF-001 코드 발급·유효·스냅샷 | CodeService(8자·7일·교체)·`ReferralCode.live`·가입 422 | code_service 4(발급/verify/재발급/rotate_all)·referral_code 4(유니크/active?/live/형식)·registrations 3(유효 매핑+스냅샷·만료 422·무효 422·대소문자 정규화)·E2E 로테이션 무영향 |
| REF-002 첫 결제 20% 1회·멱등 | DiscountService 원자 claim | discount_service 6(적용/재결제/비추천/환불 재결제/5동시 경쟁 1회/원단위 반올림)·payment F10 6(첫 할인+ledger/2차 정상가/비추천 회귀/수수료 실패 무시/할인 실패 폴백/**롤백 claim 원복→재시도 재적용 신규**)·E2E 24,000 징수 |
| REF-003 수수료 발생·캡·징수액 기준 | CommissionService within_cap?·스냅샷 | commission_service 8(pending 생성/officer 15%/비추천·0원 제외/sales 13개월 제외·경계 포함/officer 무기한/캡 조정/집계 3종/mark_paid 사유+멱등)·payment(할인 후 징수액 기준)·dashboard 월별 집계 |
| REF-004 ledger 스냅샷 불변 | 스냅샷 컬럼·수정 경로 부재 | commission_service 1(요율 변경 후 기존 불변·신규 신요율)·commission_ledger 3(스냅샷 불변/month 형식/paid→paid_at) |
| REF-005 직원 스코프·접근 | Sales::BaseController·DashboardService 단일 경로 | dashboard_service 4(피판매 본인만·개인정보 미수집/월별 타직원 제외/위임 스코프/active_code)·sales controllers(대시보드 본인만/비로그인 리다이렉트/세션 키 분리/연도 클램프)·sales_rep referred_tenants 원천 |
| REF-006 가입 휴대폰 인증 | PhoneVerificationService(bcrypt·5회·1분·원자 소비)+create 서버 검증 | phone_verification 11(bcrypt 평문 없음/정규화/1분 리밋/타번호/재발송 무효화/verified_at/만료 거절/5회 차단/not_found/consume 원자 1회/미검증·만료 미소비)·signup_verification 4(형식/암호화 TEN-003/attempts/usable 3조건)·registrations 8(미검증 422/전화 불일치/소비 재사용 불가/**만료 직후 거절 신규**/발송·검증 액션/오류 코드 422/형식 422/429)·E2E 실제 발송→검증 플로우 |
| REF-007 정지·코드 무효·접근 차단 | suspend!(사유 필수+코드 무효화)·세션 재확인 | sales_rep 5(suspend 사유 필수/상태 변경 2차 방어/resume/로그인 잠금/삭제 restrict)·sales controllers 2(정지 로그인 차단/정지 세션 차단)·code_service 2(정지 코드 verify 실패/rotate 제외)·rotation_job 1(정지 제외)·admin 4(사유 없는 정지 422/사유 정지+감사 로그/해제 사유/지급 확정 사유+멱등)·E2E 정지 코드 가입 거절 |

전 Rule 정상/경계/예외 3분기 충족 — 누락 시나리오 없음(빠진 것 없어 신규 추가는 리뷰 권고 2건뿐).

## 4. 남은 갭 (기록·차단 아님 — 후속 과제로 이미 문서화)

1. **W-5 환불 시 ledger 역분 미구현** — v1.0 refund 기록-only 정합과 일치, 03_implementation §7-2 P1 과제 유지. refund 실이체 전환 시 REF-003 역분 테스트 필요.
2. 인증번호 발송 동기 처리(SIMULATED)는 카카오 템플릿 심사 후 Job 래핑 재검토 대상(§7-1) — 현 테스트는 SIMULATED 경로 고정.
3. 피판매 100건 상한 초과 페이징(§7-5) — 집계 테스트는 상한 내 기준.

## 5. 결론

- 리뷰 권고 2건 보강 완료(REF-002 롤백-재적용 경계·REF-006 만료 통합 경계) — 두 시나리오 모두 **현 구현 동작이 기대대로** 롤백 원복·거절을 확인(코드 버그 없음).
- REF-001~007 전 시나리오 커버·전 건 통과. 품질 게이트(rubocop 0·brakeman 0·592 tests 0 failures) 충족 — F10 Phase 7 테스트 **PASS**.
