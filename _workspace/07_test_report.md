# 07_test_report.md — F5 현금영수증 테스트 검증 (Phase 7)

- 실행일: 2026-11-16 · 프로필: wonbikok-tester-lite
- 결과: **231 runs, 969 assertions, 0 failures, 0 errors, 0 skips** — `bin/rails test` 전 건 통과
- `bin/rubocop`: 112 files, no offenses · 외부 API(포트원·솔라피·바로빌) 실호출 없음(스텁/SIMULATED만, forbid_network 방어 테스트 유지)

## 1. W3-R 해소 (리뷰 3차 권고 — 테스트 품질 강화, 소스 수정 없음)

대상: `test/jobs/cash_receipt_issue_job_test.rb` "R2(B1) retry_job 2회째 실제 재발행" 시나리오

- **문제(3차 [W3-R])**: 기존 스텁 `state()`가 첫 호출부터 3000을 반환 → 1회째 실패 후 `handle_failure`의 `lookup_existing_state`(CR-004 재조회)가 기발행으로 판정해 SyncJob 예약으로 흡수 통과. R2의 "2회째 실제 재발행 성공" 경로를 직접 검증하지 못함.
- **수정**: 스텁을 호출 횟수 기반으로 교체.
  - `state()` 1회 호출(1회째 실패 후 CR-004 재조회) = 조회 실패 → CR-004 기발행 분기 차단 → pending 복귀·retry_job
  - `state()` 2회 호출(2회째 실행 후 SyncJob 폴링) = 3000 성공
  - 검증 강화: `issue_calls == 2` 단언 추가 — regist_and_issue가 실제 2회 호출(재발행)되었음을 직접 확인(기존은 issued 상태만 단언)
- **결과**: 통과(8 runs, 29 assertions). 검증 로직 약화 없음 — 명칭·주석도 실제 경로에 맞게 정리.

## 2. 추가 보강

`test/jobs/cash_receipt_sync_job_test.rb` — C1 통합 시퀀스 신설: "2500 재폴링 → 3000 도달 시 issued 확정(중간에 issued 전이 없음)". 기존은 2500 재예약·3000 확정이 분기별로만 분산 커버되어, CR-003 핵심(비종결 상태에서 ISSUED 전이 금지 → 재폴링 후 최종 확정 + 알림 1회)을 단일 시퀀스로 검증.

## 3. CR/TEN 커버 매핑표 (리뷰 "테스트 제안" 절 대응)

| 항목 | 테스트 | 파일 | 상태 |
|:---|:---|:---|:---|
| CR-001 멱등(재트리거 skip·검증·DB 유니크·레이스 duplicate) | 4건 | cash_receipt_triggerable_test, cash_receipt_test | 기존 통과 |
| CR-002 auto PAID 허용·UNPAID 차단·manual CANCELLED만 차단(C3) | 2건 | cash_receipt_triggerable_test :34·:42 | 기존 통과 |
| CR-003 2500→재폴링→3000 issued(C1)·3000 한정 전이·즉시 issued 아님 | 시퀀스 신설 + 기존 6건 | cash_receipt_sync_job_test :94·:113(신설), :44·:77·:86, issue_job_test :86·:94 | 신설 통과 |
| CR-004 재조회 기발행 → failed 미표시 | :104 | cash_receipt_issue_job_test | 기존 통과 |
| CR-006 retry 2회째 실수행(스텁 없는 통합)·재실패 failed+알림·소진 | W3-R 수정 + 2건 | cash_receipt_issue_job_test :134·:167 | **수정 후 통과** |
| CR-005 취소 중 오류 복원(C2)·cancel_pending 3000 재폴링→7000(R1)·사유 필수 | 3건 | cash_receipts_controller_test :118, sync_job_test :119, controller :80 | 기존 통과 |
| 연습 모드 네트워크 0회(B2) — issue/sync/cancel 3경로 | 3건 | issue_job_test :191, sync_job_test :151, controller_test :145 | 기존 통과 |
| TEN-001 격리(목록·상세) | 2건 | cash_receipts_controller_test :20·:34 | 기존 통과 |
| TEN-002 주민번호 거절 | :80 | cash_receipt_test | 기존 통과 |
| TEN-003 issued_by 원문 부재(C4)·identity_num 암호화·마스킹 | 3건 | cash_receipt_test :69·:87, triggerable_test :20 | 기존 통과 |
| TEN-004 스냅샷(트리거 시 금액 스냅샷) | triggerable_test :18 | 기존 통과 |
| C5 과거 월 조회·무효 값 당월 기본 | :165 | cash_receipts_controller_test | 기존 통과 |
| C6 needs_info 보완 후 재발행·미보완 차단 | 2건 | cash_receipts_controller_test :180·:193 | 기존 통과 |
| C1 폴링 실패·MAX_POLLS 상한 | :105 | cash_receipt_sync_job_test | 기존 통과 |

## 4. 남은 갭

- **W4-R**(폴링 상한 도달 후 수동 복구 액션 부재): 상한 중단 동작은 테스트됨(:105). 복구 액션 자체는 리뷰 3차 판정대로 문서화 과제(코드 미구현)라 테스트 대상 아님.
- **알림톡→SMS 대체(MSG-002)**: F5 도메인은 MessageLog SIMULATED 기록 검증으로 충분 — 실제 채널 대체는 W2 MessageSendJob 테스트가 담당(범위 외).

## 5. 결론

W3-R 해소(스텁 호출 횟수 기반 전환 + 재발행 2회 호출 직접 검증)·C1 통합 시퀀스 보강 포함 전체 231건 통과. 리뷰 1~3차의 테스트 제안 시나리오 전건 커버. 소스 코드 수정 없음. F5 테스트 검증 완료.
