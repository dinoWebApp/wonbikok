# W2 리뷰 — 월간 청구·솔라피 알림톡(F3) + 미납 리마인더(F6) + W1 후속 3건

- 담당: W2Review / 2026-10-20
- 기준: PRD.md 7장 F3·F6(W2 경계 포함)·9장·10.2·14장(W2 확정 사항)·22장 / ARCHITECTURE_CONVENTION / 리뷰 체크리스트
- 검증 방법: 전 레이어 코드 정밀 검토 + 솔라피 공식 문서 대조(인증·발송·응답 구조) + Solid Queue·Fugit 실제 파싱 실증 + W1 코드와 상호작용(게이트·세션·스코프) 회귀 확인

## 판정

**상태: CHANGES_REQUESTED** — BLOCKER 0, **CRITICAL 5**, WARNING 7

개별 레이어 품질(스코프·검증·가드·마스킹·시크릿·외부 호출 격리)은 전반적으로 우수하나, ①발송 유일성의 DB 강제 누락 ②리마인더 D+3 단계가 D+1에 발송되는 타이밍 오류 ③월간 청구 배치가 스케줄 등록 자체에 실패(무음) ④취소 청구 발송 차단 누락 ⑤수신처 없는 청구의 SENT 선반영 — 5건은 반드시 수정 후 재검증이 필요하다.

---

## 이슈 목록

### CRITICAL

1. **[CRITICAL] MSG-001 — db/migrate/20261020000007_create_message_logs.rb:21 — 발송 유일성의 DB 강제 부재(경쟁 상태 허용)**
   `[invoice_id, template_type]` 인덱스가 unique가 아니다. 유일성은 모델 검증(`exists?`, message_log.rb:55-59)+스케줄러 사전 필터만으로, 동시 요청(09:00 배치와 수동 즉시발송 중첩, 발송 버튼 이중 제출, 잡 동시 실행)에서 검증 동시 통과 → 중복 MessageLog 삽입 → 학부모 이중 발송. PRD 14장 W2 확정 사항("[invoice_id, template_type] 발송 유일성을 갖는다")과 3중 방어 설계(DB+검증+사전 필터) 대비 DB 축이 빠졌다. invoices의 INV-001은 unique 인덱스로 완비(20261020000006:23-24)된 것과 불균형.
   **수정**: partial unique index 추가(SQLite 지원) — `add_index :message_logs, %i[invoice_id template_type], unique: true, where: "resend_of_id IS NULL", name: "index_message_logs_dispatch_uniqueness"` + Notifications::Dispatcher에서 `ActiveRecord::RecordNotUnique` rescue → duplicated 카운트(검증과 동일 처리).
   ✅ **수정 완료(W2FixDev, 2026-10-20)** — db/migrate/20261020000010_add_message_logs_dispatch_uniqueness.rb(partial unique index, 마이그레이션 up 완료) + dispatcher.rb dispatch_one이 `requires_new` savepoint별 `ActiveRecord::RecordNotUnique` rescue → :duplicated 집계. 검증: rails runner에서 insert_all! 우회 삽입 → RecordNotUnique 차단 확인, resend(resend_of_id 설정) 건은 예외 허용 확인, Dispatcher 중복 dispatch → queued=0/duplicated=1. `bin/rails test` 77 runs 0 failures 회귀 없음.

2. **[CRITICAL] F6/MSG — app/services/reminders/scheduler.rb:44-51 — D+3 단계가 기한 경과 D+1에 발송됨**
   `due_stage_for`는 경과 1~2일에도 `:d3`을 반환한다(`due_on >= date`만 nil). 매일 09:00 배치가 D+1에 reminder_d3를 발송하고, MSG-001 유일성 때문에 정작 D+3에는 재발송되지 않는다. PRD F6 "기본값 D+3(납부 기한 경과 3일)" 위반이며 코드 주석 자체("d3: 경과 3~6일")와도 불일치 — 구현 버그.
   **수정**: `days = (date - invoice.due_on).to_i` 기준으로 `:d3`는 `days >= 3`일 때만 반환(1~2일은 nil), d7·month_end는 현행 유지.
   ✅ **수정 완료(W2FixDev)** — scheduler.rb due_stage_for: month_end 판정 후 `days>=7→:d7, days>=3→:d3, 그 외 nil`(d7·month_end 기존 판정 유지). 검증: 경과 1일·2일 → nil, 3일 → :d3, 7일 → :d7 (rails runner 스모크).

3. **[CRITICAL] F3 배치 — config/recurring.yml:7 — 월간 청구 생성 배치가 스케줄에 등록되지 않음(무음 실패)**
   `at 7am on the 1st day of every month`은 Fugit이 **일회성 시각(EtOrbi::EoTime)**으로 파싱한다(실증: `Fugit.parse` → Fugit::Cron 아님). Solid Queue 1.7은 recurring 스케줄을 `Fugit::Cron`만 허용하며(`recurring_task.rb:118` ensure_schedule_supported), 무효 항목은 `select(&:valid?)`로 **에러 없이 조용히 탈락**한다(lib/solid_queue/scheduler/recurring_schedule.rb:10). 결과: `monthly_invoice_generation`은 영구 미실행(부팅 오류·로그 없음) — F3 완료 기준 "매월 1일 배치"가 수동 트리거 없이는 동작하지 않는다. (`every day at 9am`은 Fugit::Cron으로 파싱 확인 — reminder_dispatch는 정상.)
   **수정**: cron 표기로 교체 — `schedule: "0 7 1 * *"`. 배포 후 `SolidQueue::RecurringTask.pluck(:key)`에 두 잡이 모두 존재하는지 부트 검증에 추가 권장.
   ✅ **수정 완료(W2FixDev)** — recurring.yml: monthly_invoice_generation `"0 7 1 * *"`(다음 실행 11/1 07:00), reminder_dispatch도 cron으로 통일 `"0 9 * * *"`(다음 실행 당일 09:00). 검증: 3개 스케줄 전부 `Fugit.parse` → Fugit::Cron 확인(rails runner). 부트 시 RecurringTask 등록은 배포 환경 확인 권장.

4. **[CRITICAL] INV-003/9.1 — app/jobs/message_send_job.rb:10-20 + app/controllers/invoices_controller.rb:93-107 — 취소된 청구의 발송 차단 누락**
   (a) `MessageSendJob#perform`은 MessageLog 상태만 보고 Invoice 상태(CANCELLED)를 확인하지 않는다. 예약 큐가 남은 상태에서 청구를 취소하면(Invoice#cancel!은 QUEUED 로그에 대한 cancel_scheduled 연쇄 없음) 예약 시각에 **취소된 청구의 납부 안내가 실발송**될 수 있다(마킹만 가드됨). (b) `resend` 액션도 청구 상태 무검증 — CANCELLED 청구의 결과 화면에서 '다시 보내기' POST 시 취소 청구 납부 안내 재발송. PRD 9.1 CANCELLED="청구 무효화".
   **수정**: ① perform 초반에 `log.invoice.CANCELLED?`면 발송 중단+로그 FAILED("INVOICE_CANCELLED") 처리 ② resend 액션에 `@invoice.CANCELLED?` 차단 ③ (권장) Invoice#cancel!이 자신의 QUEUED MessageLog에 cancel_scheduled 연쇄.
   ✅ **수정 완료(W2FixDev)** — ① message_send_job.rb perform 초반 `log.invoice.CANCELLED?` → FAILED("INVOICE_CANCELLED") 중단 ② invoices_controller#resend 상태 검증(SENT/UNPAID/OVERDUE만 허용, 그 외 results 리다이렉트+alert) ③ invoice.rb cancel!이 transaction 안에서 자신의 QUEUED MessageLog 연쇄 처리(잡 discard + FAILED/INVOICE_CANCELLED 기록). 검증: 취소 청구 MessageSendJob 실행 → FAILED/INVOICE_CANCELLED (rails runner 스모크), 전체 테스트 통과.

5. **[CRITICAL] 9.1/9.3 — app/controllers/invoices_controller.rb:42 — 수신처 없는 청구가 SENT로 선반영**
   즉시 발송 시 dispatch 결과와 무관하게 **모든 READY 청구를 SENT로 update!**한다. 수신처 부재(recipients_missing) 건은 MessageLog가 생성되지 않고 발송이 0건인데도 SENT 표기 → PRD 9.1 "SENT=발송 완료" 위반이고, remindable이 SENT를 전제하므로 안내를 못 받은 원생이 그대로 리마인더 흐름에 진입한다. (영구 실패 FAILED 건이 SENT로 남는 것도 동일 뿌리 — 개발 보고 §6.7 판단의 부작용이 missing 케이스로 확대된 것.)
   **수정**: 선반영 루프를 제거하고 Dispatcher가 실제 큐에 넣은 invoice_id 목록을 Result로 반환 → 해당 건만 SENT 전이. 또는 선반영 없이 MessageSendJob의 `mark_invoice_sent!`에 완전 위임(즉시 발송은 비동기 수 초 내 전이 — 결과 화면이 상태의 유일 진실원).
   ✅ **수정 완료(W2FixDev)** — send_batch의 전체 READY 선반영 루프 제거. Dispatcher Result에 dispatched_invoice_ids 추가(실제 큐 등록 건만) → 컨트롤러가 즉시 발송 시 해당 건만 mark_sent!(READY 가드 재사용). 수신처 없는 건은 SENT 미표기. 예약발송은 잡 완료 시 mark_sent!. 검증: dispatched_invoice_ids 반영 확인 + 전체 테스트 통과.

### WARNING

6. **[WARNING] INV-006 — app/models/invoice.rb:70-88 — 발송 후·취소 후 금액 조정 허용**
   `adjust!`는 DRAFT 여부만 검사한다 — SENT/UNPAID/OVERDUE/**CANCELLED** 청구도 사유와 함께 조정액 수정 가능. PRD INV-006 "발송 전까지 수정 가능". 취소 청구 금액이 변경되면 W3 수납 정합에도 혼선. **수정**: `return false unless DRAFT? || READY?` 가드 + edit/update 진입 제한.
    ✅ **수정 완료(W2FixDev)** — invoice.rb adjust! 선두 `unless DRAFT? || READY? → errors.add(:status, :invalid); false` + 컨트롤러 edit 진입 제한(SENT 이후·취소 청구는 results 리다이렉트+alert, ko.yml invoices.errors.not_editable 추가).

7. **[WARNING] — app/models/invoice.rb:63 + app/controllers/invoices_controller.rb:78-88 — 취소 빈 사유 직접 POST 시 500**
   `cancel!`이 빈 사유에 `raise ArgumentError` → 컨트롤러의 422 분기(errors.add 경로)는 도달 불가. 폼 `required`(cancel.html.erb)로 일반 경로는 막히지만 직접 POST는 서버 오류. **수정**: raise 대신 `errors.add(:cancel_reason, :blank)` + `return false`(컨트롤러 의도와 정합).
    ✅ **수정 완료(W2FixDev)** — cancel!이 빈 사유에 `errors.add(:cancel_reason, :blank)` + false 반환(raise 제거, 컨트롤러 422 분기 도달 가능). 참고: 성공 경로는 transaction 블록 후 명시적 `true` 반환.

8. **[WARNING] — app/models/message_log.rb:29 — `has_many :resends` FK 오타(잠재 런타임 오류)**
   `foreign_key: :resend_of` → 실제 컬럼은 `resend_of_id`(schema.rb:59). 호출 시 SQLite "no such column" 오류. 현재 호출부 없음. **수정**: `foreign_key: :resend_of_id`(또는 옵션 생략).
    ✅ **수정 완료(W2FixDev)** — message_log.rb `foreign_key: :resend_of_id`로 수정.

9. **[WARNING] MSG-005 — config/solapi.yml — 발신자 표기가 서비스 공통(원장별 채널/번호 아님)**
   `from`·`pfId`가 원비콕 서비스 단일 값 — 리마인더/안내의 발신번호·채널 프로필이 원장 기준이 아님(MSG-005 "원장의 채널/번호 기준"). 본문 원장상호·원장전화 포함으로 부분 충족하며, 원장별 카카오채널 연동은 W2 범위 밖이므로 **판단 사항으로 PRD 14장(또는 F6)에 명시하고 per-tenant 채널 연동을 P1 과제로 남길 것**을 권고. (기록용 — 코드 수정 불요)
   ✅ **처리 완료(W2FixDev)** — 코드 수정 대상 아님(권고 사항). 원장별 카카오채널/발신번호 per-tenant 연동은 P1 과제로 유지 — 오케스트레이터가 PRD 14장 명시 필요.

10. **[WARNING] MSG-007 — app/controllers/invoices_controller.rb:132-134 — 예약 시각 파싱 실패 시 즉시 발송 폴백**
    `Time.zone.parse(무효값)` → nil → `send_at: nil`로 **예약 선택이 즉시 발송으로 변질**. **수정**: scheduled 파라미터 존재 시 parse 결과 nil이면 422(또는 폼 required + 서버 검증).
    ✅ **수정 완료(W2FixDev)** — send_batch에서 `params[:scheduled].present? && parse_send_at.blank?` → invoices_path 리다이렉트+alert(ko.yml invoices.errors.invalid_send_at 추가)로 즉시 발송 변질 차단.

11. **[WARNING] — app/controllers/invoices_controller.rb:17-19 — 수동 생성 target_month 미검증**
    `params[:target_month]` 무효값("2027-13" 등) → Generator `due_on_for`의 `Date.parse`에서 ArgumentError 500. **수정**: 컨트롤러에서 `/\A\d{4}-(0[1-9]|1[0-2])\z/` 검증(무효 시 현재 월 또는 422).
    ✅ **수정 완료(W2FixDev)** — create에서 정규식 미매칭 target_month는 현재 월로 치환(500 제거).

12. **[WARNING] — app/jobs/reminder_dispatch_job.rb:8-12 — 도달 불가 사코드 잔존 + 마이그레이션 코멘트 구형**
    `defined?(Reminders::Scheduler)` 가드는 Scheduler 상시 존재로 사코드(슬라이스 마이그레이션용 임시). db/migrate/20261020000007:8 주석도 폐기된 tone 기반 template_type 잔존. **수정**: 가드 제거, 주석 갱신(클린 커트오버 완결).
    ✅ **수정 완료(W2FixDev)** — reminder_dispatch_job.rb defined? 가드 제거(Scheduler 직접 위임), 20261020000007 마이그레이션 template_type 주석을 단계 기반 값으로 갱신.

---

## 검증 결과 — 문제없음 확인(근거)

| 항목 | 판정 | 근거 |
|:---|:---|:---|
| MSG-002 대체발송 파라미터 | ✅ | 공식 문서 대조: `kakaoOptions.disableSms` 기본 false=자동 대체발송, 대체발송에 사전등록 `from` 필수 — 구현(client.rb:89-98) 정확 |
| MSG-002 HMAC 인증 | ✅ | 공식 문서 스키마와 완전 일치: `HMAC-SHA256 apiKey=…, date=<ISO8601 UTC>, salt=<24hex>, signature=HMAC-SHA256(secret, date+salt)`(client.rb:166-171). 시크릿은 signature 생성에만 사용, 로그/예외 메시지 노출 없음 |
| MSG-002 응답 파싱 | ✅ | 공식 응답 구조와 정합: `failedMessageList`(접수 실패) / `groupInfo.count.sentReplacement`(대체발송) / `messageList[].messageId·statusCode` / `showMessageList` 실존 파라미터. 단건 요청 가정의 그룹 카운트 판별은 개발 보고 §7.2에 이미 리스크 표기(다건 확장 시 재확인) |
| MSG-003 재시도 상한 1회 | ✅ | message_send_job.rb:70-75 — `executions <= 1` → retry_job(5분) 1회, 이후 FAILED 확정. ConfigError는 무재시 즉시 확정(합리적) |
| MSG-006 야간 금지·이월 | ✅ | remind_send_hour 9..17 모델 검증(tenant.rb:28) + send_time_for이 18시~08시 호출을 익일 설정 시각으로 이월(scheduler.rb:83-90) + 수동 발송 동일 적용(deliver_now) |
| MSG-004 제외 즉시 배제 | ✅ | `remindable`이 students.excluded_from_reminders 조인 배제(invoice.rb:36-42) + 매 배치 재판정 + 토글 즉시 반영 |
| MSG-007 예약 취소 | ✅ | QUEUED만 취소(cancellable?), 잡 discard + 로그 제거 + READY 복귀. 취소-발송 경합은 로그 소멸→잡이 log nil 조기 종료로 안전 |
| INV-001 중복 청구 금지 | ✅ | DB unique 인덱스(migration:23-24) + 모델 검증 + Generator 멱등 skip 3중 |
| INV-003 취소 제외 | ✅ | `billable` + `remindable` 모두 CANCELLED 배제 |
| INV-004 휴원·퇴원 제외 | ✅ | Generator가 Student.active만, paused/withdrawn 배제 |
| TEN-001 격리 | ✅ | invoices·message_logs·reminders 전 경로 `current_tenant` 스코프, cancel_queue도 tenant 스코프 find. Model 조인 경로도 invoice 소유로 간접 격리 |
| TEN-004 스냅샷 | ✅ | Generator가 student_name_snapshot·base_amount 복제, Invoice는 원비 실시간 참조 없음 |
| TEN-003 마스킹 | ✅ | preview/index/show 전부 masked_phone, 원장 전화는 메시지 본문에만 사용 |
| practice·키 미설정 | ✅ | MessageSendJob.simulated?가 practice·빈 키를 실호출 전 차단 → SIMULATED 기록. 외부 HTTP는 Service(Client)+Job 외 부재 |
| 단계 클린 커트오버 | ✅ | 코드·ko.yml·solapi.yml에 reminder_soft/standard/formal 잔존 없음(마이그레이션 주석만 — 이슈 12) |
| 단계 중복·누락 경계 | ✅(설계) | 단계별 template_type 상이로 MSG-001이 단계당 1회 강제, 배치 재실행 멱등. d7 윈도우가 month_end에 흡수되는 달(말일 근접 기한)의 건너뜀은 개발 보고 판단 2·3과 부합 |
| W1 후속 ① 게이트 | ✅ | ApplicationController 전역 ensure_onboarding_complete, sessions/registrations/onboarding만 skip(정확), require_authentication이 선행하도록 선언 순서 정상, redirect_after_login 이중 방어 |
| W1 후속 ② 로그아웃 캐시 | ✅ | sessions#destroy에서 CSV 오류내역 캐시 delete + 세션 키 제거 |
| W1 후속 ③ bank_info | ✅ | Tenant presence on: :bank_info + valid?(:bank_info) 선행(business_info 패턴 재사용) |
| W1 회귀 | ✅ | students_controller_test 픽스처 보정은 게이트 도입의 직접 결과이며 검증 대상(TEN-001 캐시 격리) 불변. 온보딩 완료 테넌트 기존 흐름 영향 없음 |
| Turbo·params | ✅ | 성공 303 see_other / 실패 422, params.expect 사용, HEAD verb confusion 해소(cancel GET/POST 분기) |

---

## 테스트 제안 (Tester 전달 — Rule ID)

1. **MSG-001 동시성**: 동일 청구+동일 template_type에 대해 2스레드 동시 dispatch → 최종 1건만 저장(수정 후 partial unique 인덱스), 한 건은 duplicated 집계. resend_of 연결 건은 유일성 예외+이력 배지 확인.
2. **F6 단계 타이밍(경계값)**: due_on이 어제(D+1)/2일 전(D+2)인 청구 → 배치 후 미발송(수정 후). 3일 전 → d3 발송. 6일/7일 전 → d3 없음+d7. 대상월 말일-2/-1 → d7에서 month_end로 전환. 기한 25일처럼 d7 도래 전 month_end가 먼저인 달 → month_end 단독 1회 확인.
3. **취소 상호작용**: READY 청구 예약 발송 직후 청구 취소 → 예약 시각 경과 후에도 발송·SENT 전이 없음(수정 후). 취소 청구 results에서 '다시 보내기' 차단(수정 후).
4. **수신처 부재**: 보호자 없는 READY 청구 즉시 발송 → Invoice가 SENT로 변하지 않고 missing 카운트 노출(수정 후).
5. **MSG-003**: 네트워크 오류 스텁 → retry_job 정확 1회, 2회째 FAILED 확정, provider 미호출 재확인. ConfigError는 재시도 0회.
6. **배치 등록**: 부팅 시 `SolidQueue::RecurringTask`에 monthly_invoice_generation·reminder_dispatch 키 존재(수정 후). MonthlyInvoiceGenerationJob 재실행 → created=0/skip=N 멱등.
7. **INV-006 경계**: SENT·CANCELLED 청구 조정 POST → 422 거부(수정 후), DRAFT는 사유 없이 성공.
8. **cancel 사유**: 빈 사유 직접 POST → 500 아닌 422+폼(수정 후).
9. **W1 회귀**: 온보딩 미완료 세션의 /invoices /reminders /students /dashboard 직접 접근 전부 온보딩 리다이렉트, 로그아웃 후 CSV 캐시 키 소멸, step3 빈 계좌 422.
10. **SIMULATED 격리**: practice 테넌트·키 미설정에서 MessageSendJob 실행 시 HTTP 스텁 호출 카운트 0, MessageLog SIMULATED + Invoice SENT.

## 재검증 범위 (Phase 6 수정 후)

이슈 1~5(CRITICAL) 수정분 전수 + 이슈 6~8, 10~11(해당 파일 회귀). 이슈 9·12는 문서/사코드 정리 확인만. MSG-001·F6 단계·취소 상호작용은 상용 전 반드시 재스모크.
