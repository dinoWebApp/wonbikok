# W2 테스트 보고서 — F3 월간 청구·솔라피 알림톡 + F6 미납 리마인더

- 담당: W2Test / 2026-10-20
- 결과: **135 runs, 533 assertions, 1 failure + 1 error — 모두 코드 버그**(아래 참조), 테스트 오류 0
- 품질 게이트: `bin/rubocop` 85 files **no offenses** / 기존 테스트 77건 회귀 0

## 1. 통계

| 구분 | 파일 | 테스트 |
|:---|:---|:---|
| 모델 | test/models/invoice_test.rb | 10 (INV-001/002/003/004/006, TEN-004) |
| 모델 | test/models/message_log_test.rb | 7 (MSG-001, MSG-007) |
| 서비스 | test/services/notifications_dispatcher_test.rb | 8 (MSG-001/007, C5) |
| 서비스 | test/services/reminders_scheduler_test.rb | 14 (C2 회귀, MSG-004/006, INV-003) |
| 잡 | test/jobs/message_send_job_test.rb | 9 (MSG-002/003, C4, SIMULATED) |
| 잡 | test/jobs/monthly_invoice_generation_job_test.rb | 2 (멱등, C3 크론 회귀) |
| 통합 | test/integration/w2_invoices_flow_test.rb | 8 (TEN-001, 게이트, INV-002/006, C4/C5, W10, MSG-007) |

공용: test/test_helper.rb에 `create_owner_user`(name 인자 추가)·`create_invoice` 헬퍼 추가. 외부 API는 `FakeSolapiClient`(호출 카운터) + `Solapi::Client.from_credentials` 싱글턴 교체로 **실호출 0**.

## 2. 발견 코드 버그 (수정 없이 보고 — Developer 전달 필요)

### 버그 1 [MSG-003 위반] 재시도 상한 1회가 실제로는 2회 — app/jobs/message_send_job.rb:71
`handle_retry_or_fail`의 조건이 `executions <= MAX_AUTO_RETRIES(1)`. ActiveJob은 재시도 시점에 executions를 증가시키므로 **2차 실행(executions=1)에서도 재시도가 큐에 등록**되고, 3차(executions=2)에야 FAILED 확정 → 초기 발송 + 자동 재시도 2회. PRD MSG-003 "재시도 상한 1회" 및 리뷰 검증표("executions <= 1 → 1회")와 불일치(리뷰어 판정 오류로 추정).
- 재현: test/jobs/message_send_job_test.rb "MSG-003 2차 실패 후에는 재시도 없다" — NETWORK_ERROR 스텁, executions=1로 실행 시 재시도 잡 1건이 추가로 큐에 등록됨(failure).
- 수정 제안: `executions < MAX_AUTO_RETRIES` (executions=0만 재시도).

### 버그 2 [INV-002 500 오류] 수정 실패(사유 누락 422) 재렌더 시 서버 오류 — app/views/invoices/edit.html.erb:36
`f.text_field :change_reason`인데 Invoice에 `change_reason` 속성(컬럼/가상 어트리뷰트)이 없음. 정상 경로(DRAFT 편집)에서는 `@needs_change_reason=false`로 필드가 렌더되지 않아 발견되지 않았으나, **READY 청구를 사유 없이 수정해 422로 `render :edit` 되는 순간 ActionView::Template::Error(500)** 발생. INV-002 사유 필수 UX가 실제로는 동작 불가.
- 재현: test/integration/w2_invoices_flow_test.rb "INV-002 READY 청구 수정은 사유 없이 422..." — 두 번째 patch(사유 있음) 도달 전 첫 422 렌더에서 에러(error).
- 수정 제안: Invoice에 `attr_accessor :change_reason` 추가 또는 뷰를 `text_field_tag :invoice[change_reason]`로 변경.

## 3. 리뷰어 시나리오 10건 매핑

| # | 시나리오 | 테스트 | 결과 |
|:--|:---|:---|:---|
| 1 | MSG-001 동시성(partial unique + duplicated) | message_log_test(인덱스·우회 삽입), dispatcher_test(RecordNotUnique 흡수·resend 예외) | ✅ |
| 2 | F6 단계 타이밍 경계값 | reminders_scheduler_test(1·2일 nil, 3·6일 d3, 7일 d7, 월말 D-1, month_end 흡수) | ✅ (C2 수정분 회귀 확인) |
| 3 | 취소 상호작용 | invoice_test(연쇄 차단), message_send_job_test(INVOICE_CANCELLED 가드), w2_invoices_flow_test(재발송 차단) | ✅ |
| 4 | 수신처 부재 → SENT 미전이 | dispatcher_test(missing 집계·dispatched ids), w2_invoices_flow_test(C5) | ✅ |
| 5 | MSG-003 재시도 상한 | message_send_job_test 3건 | ❌ **버그 1** |
| 6 | 배치 등록(크론)·멱등 | monthly_invoice_generation_job_test(Fugit::Cron 전건, 재실행 created=0) | ✅ |
| 7 | INV-006 경계 | invoice_test(SENT·CANCELLED 조정 차단, DRAFT 자유), w2_invoices_flow_test | ✅ |
| 8 | cancel 빈 사유 422 | invoice_test(errors.add+false), 통합 cancel 404 격리 | ✅ |
| 9 | W1 회귀(게이트) | w2_invoices_flow_test(온보딩 게이트 3경로) | ✅ |
| 10 | SIMULATED 격리 | message_send_job_test(practice 0호출 카운터) | ✅ |

## 4. Rule ID 커버리지

| Rule ID | 검증 내용 | 상태 |
|:---|:---|:---|
| INV-001 | 모델 검증 + DB 유니크(우회 삽입 RecordNotUnique) + Generator 멱등 skip | ✅ |
| INV-002 | READY 조정 사유 필수 + change_history 기록 / DRAFT 무사유 | ⚠️ 로직은 통과, 재렌더 500 = 버그 2 |
| INV-003 | billable·remindable·sendable 제외 + 취소 시 QUEUED 연쇄 FAILED + 잡 가드 | ✅ |
| INV-004 | paused 제외(excluded=1), active만 생성 | ✅ |
| INV-006 | DRAFT→READY confirm 전제, SENT/CANCELLED 조정 차단 | ✅ |
| MSG-001 | 모델 검증 + partial unique 인덱스(where절 포함) + RecordNotUnique duplicated + resend_of 예외·resends 연결 + 단계별 유일성 + 배치 재실행 멱등 | ✅ |
| MSG-002 | fallback:true 응답 → FALLBACK_SENT 기록 + 청구 SENT | ✅ |
| MSG-003 | 1차 실패 재시도 1회 / ConfigError 0회 | ❌ 버그 1 |
| MSG-004 | 제외 토글 직후 배치 대상 탈락 | ✅ |
| MSG-006 | 08시→당일 9시, 야간 22시→익일 9시, 23시 설정→17시 클램프 | ✅ |
| MSG-007 | QUEUED만 취소, 예약 등록→취소(로그 제거·READY 복귀), 무효 시각 즉시발송 변질 차단(W10) | ✅ |
| TEN-001 | 타 테넌트 invoice 조회·취소·재발송·예약취소 전부 404 + 로그 보존 | ✅ |
| TEN-004 | 원생 이름·원비 변경 후 스냅샷 불변 | ✅ |

## 5. Phase 6 수정분(C1~C5) 검증 결과

| 항목 | 검증 | 결과 |
|:---|:---|:---|
| C1 partial unique 인덱스 | 인덱스 존재(where "resend_of_id IS NULL") + 우회 삽입 차단 + Dispatcher rescue | ✅ |
| C2 d3 경계 | 경과 1·2일 nil / 3일 d3 / 6일 d3 / 7일 d7 | ✅ |
| C3 크론 등록 | recurring.yml 전 schedule Fugit::Cron 파싱 | ✅ |
| C4 취소 발송 차단 | 잡 가드 FAILED(INVOICE_CANCELLED)·클라이언트 0호출, cancel! 연쇄, resend 차단 | ✅ |
| C5 SENT 선반영 제거 | 수신처 없는 건 READY 유지 + missing 집계 + dispatched ids만 전이 | ✅ |

## 6. 실패 원인 분류 요약

- 1 failure + 1 error: **모두 코드 버그**(§2) — 테스트 오류·플레이크 0. 해당 2개 테스트는 버그 수정 후 즉시 통과되도록 규칙 기준으로 작성됨(수정 시 테스트 변경 불요).

## Phase 6-2 수정 후 재실행 (W2Fix2Dev / 2026-10-20)

| 항목 | 수정 | 재검증 |
|:---|:---|:---|
| 버그 1 [MSG-003] | message_send_job.rb:89 — `executions <= MAX_AUTO_RETRIES` → `executions <` (executions=0만 재시도) | ✅ "MSG-003 2차 실패 후에는 재시도가 없다" 통과 — 2차 실패에서 재시도 잡 0건, FAILED/NETWORK_ERROR 확정 |
| 버그 2 [INV-002] | invoice.rb — `attr_accessor :change_reason` 추가(가상 어트리뷰트, 컨트롤러 invoice_params[:change_reason] 경로와 정합) | ✅ "INV-002 READY 청구 수정은 사유 없이 422, 사유와 함께 성공한다" 통과 — 422 재렌더 Template::Error 소멸 |

- 결과: **135 runs, 541 assertions, 0 failures, 0 errors** — 테스트 파일 변경 없음
- 품질 게이트: `bin/rubocop` 85 files no offenses / `bin/brakeman` No warnings found
