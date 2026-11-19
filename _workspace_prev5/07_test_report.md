# 07_test_report.md — W4 병렬 배치 테스트 게이트 (Phase 7-S)

- 실행일: 2026-11-18 · 프로필: wonbikok-tester · 판정: **PASS**
- 범위: 1·2차 리뷰 "Tester 전달(중점)" 시나리오 고정 + 전체 게이트
- 제약 준수: 소스(app/) 수정 0건 — 변경은 테스트 파일 7개에 한함

## 1. 게이트 결과 (실측)

| 게이트 | 결과 |
|---|---|
| `bin/rails test` | **490 runs, 2,216 assertions, 0 failures, 0 errors, 0 skips** (2차 리뷰 485 기준 +5 runs / +62 assertions) |
| `bin/rubocop` | 170 files inspected, **no offenses** |
| `bin/brakeman` | **No warnings found** |

- 실패 원인 분류: 게이트 진행 중 1건(서비스 CSV 3행 테스트)이 픽스처 원생명 "박도윤"과의
  이름 충돌로 실패 → **테스트 오류**(코드 버그 아님 — CSV 행 자체는 정상 오류행 처리됨).
  테스트 데이터명을 "초과원생"으로 변경 후 재실행 통과. 소스 수정 없음.

## 2. 외부 실호출 격리 확인 (전부 유지)

| 연동 | 격리 장치 | 확인 |
|---|---|---|
| 포트원 | `Portone::BillingService` SIMULATED 이중 게이트(api_key 미등록 OR `PORTONE_LIVE!=1`) + 테스트 네트워크 스파이(`Net::HTTP.new` 접촉 시 예외) — portone_billing_service_test 5건 전부 통과 | ✅ |
| 솔라피 | `FakeSolapiClient` 스텁 주입(from_credentials 교체·teardown 복원) — message_send_job_test | ✅ |
| 바로빌 | 스텁 XML 파싱만(직접 HTTP 규격 스텁) — barobill_services_test | ✅ |
| 트리거 | CashReceipt::Triggerable — Job enqueue 단정까지만(발행 실호출 없음) | ✅ |

## 3. 리뷰 제안 시나리오 — 보강/생략 내역

### 3.1 SUB-001 CSV 경계 회귀 고정 — 보강 3건 (신규)

Phase 6 기존 6건(컨트롤러 4: 상한 422·잔여1×2행·휴원 집계 제외·레거시 create / 서비스 2:
잔여1×2행·휴원·퇴원 무소진)과 중복되지 않는 경계만 추가:

| 테스트 | 파일 | 내용 |
|---|---|---|
| 잔여 1 슬롯에 재원 3행은 1성공/2오류행(SUB-001) | students_csv_import_service_test.rb | 초과 행 **2행 이상**이 각각 행번호(3·4)와 "잔여 슬롯" 사유로 수집됨 — 기존은 2행/1오류뿐 |
| 재원·휴원 혼합 파일에서 휴원 행 무소진(SUB-001) | students_csv_import_service_test.rb | 재원2+휴원1·잔여1 → 재원1성공+재원1오류(3행)+휴원1성공 — 혼합 파일에서 INV-004 무소진 |
| 레거시 계정 CSV 등록 상한 없이 처리(SUB-001) | students_controller_test.rb | 구독 부재(nil=레거시) 단정 + CSV import 200 — 기존 레거시 핀은 create 경로만, C-1 대상 경로인 CSV는 미핀 |

### 3.2 ADM-001/002 — 보강 4파일 (기존 테스트 강화)

| 항목 | 판단 | 내용 |
|---|---|---|
| 사유 없는 4조치 422 | 기존 커버 | 플랜 변경·연장·정지·해제(tenant_actions 4건) + 환불(subscription_payments) — 전부 존재 |
| **audit 미기록 단정** | **보강** | 기존 422 단정에 audit 부재 단정이 없었음 → `assert_rejected_without_reason` 헬퍼가 `AuditLog.count` 무증가 + 조치별 action·target 부재를 단정하도록 강화(플랜 변경·연장·정지·해제 4건에 일괄 적용). 환불 테스트도 `refund_confirmed` audit 미기록 + `AuditLog.count` 무증가 추가 |
| **마스킹 원문 미노출** | **보강** | index는 기존 단정 존재(사업자번호·휴대폰 원문 `assert_no_match`) → 상세(show) 화면에 원문 2종 미노출 단정 추가(열람 audit이 발생하는 화면) |
| OTP 5회 잠금(비밀+OTP 합산) | 기존 커버 — 생략 | sessions_controller_test "5회 실패(1·2단계 합산)" = 비밀번호 3회 + OTP 2회 → locked? + `account_locked` audit + 잠금 후 올바른 자격 차단까지 단정. 모델 경계(admin_user_test 4회 미잠금/5회 잠금)도 존재 |

### 3.3 trial_extended 렌더 — 신규 1건

| 테스트 | 파일 | 내용 |
|---|---|---|
| trial_extended 이벤트 라벨이 구독 이력에 정상 렌더(C-2) | subscriptions_controller_test.rb | `trial_extended` 이벤트 생성 → 원장 구독 화면에서 `subscriptions.events.trial_extended`("체험 연장") 라벨 렌더 + `translation_missing` 부재 단정. 기존의 enum 전수×키 존재 단정(subscription_test C-2)의 **실렌더 보강** — 3-S ko.yml 병합 완료 후 단정 가능해짐 |

### 3.4 F7 정합 — 신규 1건 + 기존 커버 확인

| 항목 | 판단 | 내용 |
|---|---|---|
| **미확인 입금 수 = payments#index 기준 일치** | **신규** | dashboard_controller_test: 혼합 데이터(미완납 3 + 초안·취소·완납·타월 제외 4) → 대시보드 할 일 "3명" 렌더 단정 + payments 화면 미완납 행 수 3(수납 등록 링크 셈)과 **일치 단정** + 초안·취소(INV-003)·타월 원생명 미노출. 기존 서비스 테스트는 기준 병렬 재구현이라 실렌더 핀이 없었음 |
| 취소 청구(INV-003) 정산 제외 | 기존 커버 — 생략 | summary_service_test 2건(지표 정산 취소 200,000 제외·취소 전환 수납 정산 미포함) |
| PAID×미발행 잔여 | 기존 커버 — 생략 | summary_service_test(issued 없는 PAID만·failed 보유도 대상) + dashboard_controller_test(무발행 원생 노출) |

### 3.5 SUB-002/003 — 생략 (전부 기존 커버, 사유: f8 테스트와 중복)

| 시나리오 | 기존 테스트 (중복이므로 미추가) |
|---|---|
| 3회 실패 → past_due 전이 | retry_policy_service_test "2회까지 active, 3회 past_due + 보관 만료일 기록"(SUB-002) |
| suspend! | retry_policy_service_test "past_due에서만 허용 + suspended 이벤트 + 재정지 거절"(SUB-002) |
| 재개 | payment_service_test "suspended 상태에서 수동 결제하면 재활성화(SUB-002 정지 해제)" |
| D+30 카운트다운 | retry_policy_service_test "past_due 시점 + 30일 — remaining 30/1/0/-1"(SUB-003) + subscriptions_controller_test past_due 배너 렌더 |

## 4. Rule ID 커버 매핑 (본 배치 보강분)

| Rule ID | 보강 테스트 | 정상/경계/예외 |
|---|---|---|
| SUB-001 | CSV 잔여 1×3행(경계)·혼합 행 무소진(정상)·레거시 CSV 통과(정상) | 3건 |
| ADM-001 | 사유 없는 5조치 × audit 미기록 단정(예외 — 기존 422 테스트 강화) | 5건 강화 |
| ADM-002/TEN-003 | admin 상세 마스킹 원문 미노출(정상 — 기존 테스트 강화) | 1건 강화 |
| C-2(i18n) | trial_extended 원장 화면 라벨 렌더(정상) | 1건 |
| F7/INV-003 | 대시보드↔payments 미확인 입금 기준 일치(정합) | 1건 |

## 5. 남은 갭 (테스트 범위 밖 — 기록)

1. SUB-002 자동 정지 주체(배치)·데이터 삭제 배치(SUB-003 이행)·포트원 실호출(P1) — 02_prd_update 후속 과제로 문서화됨. 구현 전 테스트 대상 아님.
2. 관리자 정지 실차단(v1.0 이력 기록만) — 후속 구현 시 TEN 측 차단 테스트 필요.
3. 관리자 OTP 테스트는 개발 폴백 시크릿 경유(Rails.env.local? 한정 — otp_service.rb:83-84). 운영 otp_seed 운용 시 RFC 벡터 테스트로 대체 커버됨(otp_service_test).
4. 체험 D-7 알림 잡은 SIMULATED 로그+캐시 마커 — 실발송 전환 시 발송 유일성 저장소 확장과 함께 테스트 보강 필요(integ §5.1).

## 6. 결론

**PASS** — 1·2차 리뷰의 Tester 전달 항목을 5건 신규 + 3파일 기존 테스트 강화로 고정.
전체 게이트(490 runs·RuboCop 0·Brakeman 0) 통과, 외부 실호출 장치 유지, 소스 수정 0.
코드 버그 0건(진행 중 1건 실패는 테스트 데이터명 충돌 — 테스트 오류로 분류·수정).
