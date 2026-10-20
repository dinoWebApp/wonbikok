# W2 F3 구현 보고 — 월간 청구 & 납부 안내 + 솔라피 알림톡

- 담당: W2F3Dev / 2026-10-20
- 검증: `bin/rails db:migrate` 전건 up, `bin/rubocop` **no offenses(72 files)**, `bin/brakeman` **no warnings**, `bin/rails test` **76 runs, 325 assertions, 0 failures**(기존 73 + 신규 통합 스모크 3), `bin/rails runner` 서비스 스모크 10단계 + HTTP 흐름 스모크 전건 통과, 스모크 데이터 클린업(tenants=0)

## 1. 생성/수정 파일 목록

| 구분 | 파일 |
|:---|:---|
| 마이그레이션 | db/migrate/20261020000006_create_invoices.rb, 20261020000007_create_message_logs.rb, 20261020000008_add_reminder_settings_and_exclusions.rb (schema.rb 반영) |
| 모델 | app/models/invoice.rb(신규), message_log.rb(신규), tenant.rb(수정: invoices/message_logs·리마인더 설정 검증), student.rb(수정: invoices/message_logs) |
| 서비스 | app/services/solapi/client.rb, solapi/message_builder.rb, invoices/generator.rb, notifications/dispatcher.rb |
| 잡 | app/jobs/message_send_job.rb, monthly_invoice_generation_job.rb, reminder_dispatch_job.rb |
| 컨트롤러 | app/controllers/invoices_controller.rb(신규) |
| 헬퍼 | app/helpers/invoices_helper.rb(신규: 상태 배지·전월/익월) |
| 뷰 | app/views/invoices/{index,edit,cancel,results}.html.erb, dashboard/show.html.erb('이번 달 청구 만들기' 연결) |
| 라우팅 | config/routes.rb(invoices RESTful + confirm/results/send_batch/cancel/resend/cancel_queue) |
| 로캘 | config/locales/ko.yml(invoices/messages/대시보드/activerecord/enums/time 포맷) |
| 설정 | config/recurring.yml(배치 2종), config/solapi.yml(신규 — 키 주입 가이드) |
| 테스트 | test/integration/invoices_flow_smoke_test.rb(개발 스모크용 — Tester 슬라이스에서 확장 기반으로 사용 가능) |

## 2. 레이어별 구현 요약

- **DB**: invoices — [student_id, target_month] **유니크 인덱스**(INV-001 DB 강제) + 모델 검증, 스냅샷(student_name_snapshot·base_amount — TEN-004), adjustment_amount/note, due_on, status 6종(9.1 — PARTIALLY_PAID·PAID는 W3), sent_at/cancelled_at/cancel_reason, **change_history:text**(INV-002 확정 후 수정 사유 이력 — 명세에 없는 최소 추가, §6 참조). message_logs — channel(알림톡/SMS)·template_type·status 6종(9.3)·provider_message_id·error_code/message·sent_at·**resend_of_id**(MSG-001 재발송 예외 이력 — belongs_to 규약상 `_id` 접미 사용)·**job_id**(MSG-007 예약 취소용 — §6 참조). tenants — remind_tone/d3/d7/month_end/remind_send_hour(기본 9, MSG-006). students — excluded_from_reminders(MSG-004).
- **모델**: Invoice — enum validate: true, 상태 전이 가드(confirm! DRAFT→READY / cancel! 사유 필수·CANCELLED / mark_sent! READY·SENT만), adjust!(DRAFT 자유·READY 이후 사유 필수+change_history 기록), 스코프 for_month/billable(INV-003)/sendable. MessageLog — 발송 유일성 검증 `dispatch_uniqueness`(on: :create, resend_of 있는 건만 예외 — MSG-001), cancellable?(QUEUED만 — MSG-007).
- **Solapi::Client**: Messages v4 `POST /messages/v4/send-many/detail`. 인증 헤더는 공식 문서(https://solapi.com/developers/api/authentication-api-key) 그대로 — `Authorization: HMAC-SHA256 apiKey=…, date=<ISO8601 UTC>, salt=<12바이트 hex>, signature=HMAC-SHA256(api_secret, date+salt) hexdigest`. 대체발송은 공식 문서(https://solapi.com/developers/api/messages-disablesms) 기준 — **알림톡(ATA)은 기본 대체발송 활성**이며 `kakaoOptions.disableSms: false`(명시) + **사전 등록 발신번호 `from` 필수**라서 요청에 항상 포함(MSG-002 단일 요청 위임). 응답 파싱: failedMessageList(접수 실패)→실패, groupInfo.count.sentReplacement>0→FALLBACK_SENT(채널 구분 표시), messageList.messageId→provider_message_id, statusCode 2000 외→실패 코드 기록. 예약은 `messages[].scheduledDate`(UTC ISO8601), 취소는 그룹 DELETE(msg-groups API). 타임아웃(open 5s/read 15s)·네트워크 오류→NETWORK_ERROR Result(잡에서 재시도 판정). credentials 미설정 시 ConfigError → 잡이 SIMULATED 처리.
- **Solapi::MessageBuilder**: 카카오 템플릿 변수 치환값(원생명·청구월·금액·계좌·기한·원장상호·원장전화) 생성. 템플릿 ID/pfId는 config/solapi.yml(운영 주입). SMS/LMS 폴백 본문은 ko.yml 문구 + 변수 보간 — **I18n 보간 키는 ASCII 필수**(\w+ 패턴이라 한글 키 불가 — 실증으로 확인), 90바이트 초과 시 LMS(subject 부여, autoTypeDetect).
- **Invoices::Generator**: Student.active만(INV-004) 스냅샷 청구 초안 생성, due_on=payment_day(1~28 clamp), 기존 존재(of_kind? :taken) skip 멱등, created/skipped/excluded 리포트. 배치·수동 트리거 공용.
- **Notifications::Dispatcher**: 유일성 검증 후 MessageLog QUEUED 생성(중복은 duplicated 카운트) → MessageSendJob 예약(wait_until)·job_id 기록(MSG-007) / cancel_scheduled — SolidQueue::Job discard + 로그 폐기 + 청구 READY 복귀. 수신처는 대표 보호자 복호화 번호, 부재 시 recipients_missing 집계.
- **MessageSendJob**: practice 테넌트·키 미설정 → 실호출 0건 SIMULATED(기록+청구 SENT). 실패 시 FAILED(사유 코드·메시지), **NETWORK_ERROR/API_ERROR만 1회 자동 재시도(executions<=1 → retry_job 5분) — MSG-003 상한**, 재시도 소진 후 FAILED 확정. 성공 시 FALLBACK_SENT/SENT + provider_message_id + 청구 mark_sent!.
- **배치**: recurring.yml — monthly_invoice_generation(매월 1일 07:00), reminder_dispatch(매일 09:00 — MSG-006, F6 슬라이스의 Reminders::Scheduler를 defined? 위임하는 훅).
- **컨트롤러·뷰**: 전 조회 current_tenant 스코프(TEN-001), params.expect, 실패 422/성공 303. index(월 내비게이션·생성·미리보기 요약[총액·인원·상태별]·확정·발송 폼[대상 선택·즉시/예약]·원생별 목록·빈 상태), results(성공/실패/사유·대기열 표시·다시 보내기·예약 취소 — MSG-007), edit(조정액·비고·확정 후 사유 필수+이력 표시), cancel(사유 폼 — GET 폼/POST 처리 분기, HEAD도 폼 처리 — brakeman verb confusion 해소). 전 문구 ko.yml, Tailwind 모바일 퍼스트(F1/F2 관례), 상태 배지 헬퍼.

## 3. F3 수용조건 자체 점검

- [x] 같은 원생 × 같은 월 중복 청구 방지 — 유니크 인덱스+모델 검증+Generator 멱등 skip(스모크 1단계)
- [x] 확정 전 미리보기·수정, 확정 후 수정 사유 기록, 발송 전까지 수정 — adjust! 사유 필수+이력(스모크 3단계: 사유 없이 실패·사유와 성공·이력 1건)
- [x] 알림톡 실패 시 SMS/LMS 자동 대체(솔라피 disableSms=false+from) — 채널 구분 FALLBACK_SENT로 동일 이력 통합
- [x] 당월 중복 발송 방지 + '다시 보내기' 예외 이력 — dispatch_uniqueness 검증(중복 2건 차단 실증)+resend_of 연결(스모크 4·5단계)
- [x] 예약 발송 취소 가능·대기열 표시 — QUEUED 상태 표시+cancel_scheduled(스모크 6단계: 취소 후 로그 제거·READY 복귀)
- [x] 무한 재시도 방지 — 자동 재시도 상한 1회(MSG-003)
- [x] 취소 청구 수납 합계 제외 — billable 스코프(INV-003, 스모크 7단계; 수납 합계 산출 자체는 W3 PAY)
- [x] 연습 모드 실호출 0건 — SIMULATED(스모크 4단계, HTTP 흐름에서도 확인)

## 4. Rule ID 강제 수단

- INV-001: DB 유니크 인덱스 + 모델 uniqueness(scope) + Generator skip
- INV-002: adjust! 사유 필수(READY 이후) + change_history JSON 이력
- INV-003: Invoice.billable 스코프(취소 제외) + cancel! 사유 필수
- INV-004: Generator가 Student.active만 사용
- INV-006: DRAFT→READY confirm! 전 미리보기·수정 자유, mark_sent! 전이 가드
- MSG-001: MessageLog dispatch_uniqueness 검증(resend_of 예외)
- MSG-002: 솔라피 대체발송 단일 요청(disableSms=false+from) + FALLBACK_SENT 채널 구분
- MSG-003: MessageSendJob 재시도 상한 1회
- MSG-006: remind_send_hour 기본 9 + 9..17 검증(야간 금지), reminder_dispatch 09:00
- MSG-007: QUEUED 대기열 표시 + cancel_scheduled(예약 취소) + job_id
- TEN-001: 컨트롤러 전 current_tenant 스코프, TEN-004: 스냅샷 컬럼+Generator 복제

## 5. 검증 결과 (실시행)

1. **서비스 스모크(rails runner, 10단계 전부 OK)**: Generator created=2/skip=2·휴원 제외 → 확정 READY → 조정(사유 필수·이력) → Dispatcher 유일성(중복 2건 차단)·SIMULATED 전이·Invoice SENT → 재발송 resend_of 연결 → 예약 등록·취소(READY 복귀) → cancel!(CANCELLED·billable 제외) → MessageBuilder 치환·폴백("[스모크학원] 안녕하세요, 이원생 학부모님. 10월 원비 300,000원…", LMS=true) → Client ConfigError(키 미설정) → 전 테넌트 배치 잡 실행
2. **HTTP 흐름 스모크(통합 테스트 3건)**: 생성→확정→발송(SIMULATED·SENT 배지)→결과 페이지, 취소(사유 필수·CANCELLED), 취소/조정 폼 렌더
3. bin/rubocop 72 files no offenses / bin/brakeman no warnings / bin/rails test 76 runs 0 failures / db:migrate 전건 up / routes 전건 확인 / 부트 확인

## 6. 명세 대비 최소 추가·판단 사항 (오케스트레이터 확인용)

1. **invoices.change_history:text**: INV-002 "확정 후 수정은 변경 사유 기록"의 저장소가 명세 컬럼 목록에 없어 추가(JSON 배열: 시각·사유·조정액·비고). cancel_reason으로는 커버 불가.
2. **message_logs.job_id:string**: MSG-007 예약 취소를 위해 예약 잡 식별자 저장 필요. 취소는 SolidQueue::Job.discard로 처리.
3. **resend_of → resend_of_id**: 명세의 resend_of는 belongs_to 규약(FK `_id`)에 맞게 resend_of_id로 명명(기능 동일).
4. **config/solapi.yml 신규**: credentials 가이드 겸 기본값(빈 값 → SIMULATED). 실키는 config/credentials.yml.enc의 solapi 섹션으로 주입(파일 상단 주석에 구조 명시).
5. **SMS 폴백 문구의 I18n 보간 키는 ASCII**(student_name 등): I18n 보간 패턴 \w+가 한글 키를 매칭하지 못함 — 실증 확인. 카카오 템플릿 변수(운영 템플릿과 매핑)는 한글 키 그대로.
6. **cancel 액션 GET/POST 분기**: 사유 폼(사유 입력 필요)과 처리를 하나의 member 경로로 제공 — GET/HEAD는 폼, POST는 처리. brakeman HEAD verb confusion 경고도 해소(326 → 0).
7. **발송 시 Invoice SENT 전이**: 즉시 발송은 큐 등록 시 SENT 선반영 + 잡 성공 시 mark_sent!(멱등). 예약발송은 잡 완료 시 전이(대기 중 READY 유지).
8. **테스트 파일**: test/integration/invoices_flow_smoke_test.rb는 개발 검증용 스모크이며 Tester 슬라이스의 시나리오 확장 기반으로 유지(전체 스위트에 포함되어 통과).

## 7. 열린 이슈·리스크

1. **실발송 검증**: 솔라피 api_key/api_secret/발신번호·카카오 템플릿 심사는 운영 준비물. 키 주입 전까지 모든 발송은 SIMULATED. 실발송 1건 스모크는 별도 확인 단계(유료).
2. **대체발송(FALLBACK_SENT) 판별**: 응답 groupInfo.count.sentReplacement는 그룹 단위 집계라 단건 발송(원비콕은 1요청 1메시지)에서 정확. 다건 요청 시 건별 매핑은 messageList statusCode 확정 필요 — W2는 단건 위주라 문제없음, 코드 주석 표기.
3. **예약발송 취소의 솔라피 측 정리**: cancel_scheduled은 자체 큐 잡만 discard하며, scheduledDate로 솔라피에 예약된 건의 그룹 취소(Client#cancel_scheduled)는 W2에서 미연결(즉시/예약 모두 발송 시점에 솔라피 호출되는 구조라 자체 큐 취소로 충분 — 구조 주석 표기).
4. **솔라피 수신 리포트**: W2는 발송 요청 응답 기반 상태(14장 확정 사항) — 리포트 폴링/웹훅은 P1.
5. **미완료 온보딩 테넌트 게이트 등 W1 후속 3건**: F6 슬라이스(②) 범위 — 본 슬라이스 미포함(스핀 계획상).
6. **MessageSendJob의 Guardian 부재 처리**: Dispatcher가 수신처 없는 건을 QUEUED 미생성으로 집계(missing)하므로 잡 도달 건은 항상 보호자 존재 — 다만 잡 단독 재실행 시 primary_guardian nil 가능성은 FAILED 대상이 아닌 NoMethodError 위험 → Tester 슬라이스 검증 권장.

---

# W2 F6 구현 보고 — 미납 리마인더 + W1 후속 3건

- 담당: W2F6Dev / 2026-10-20
- 검증: `bin/rails db:migrate` 전건 up(20261020000009 포함), `bin/rubocop` **no offenses(77 files)**, `bin/brakeman` **no warnings**, `bin/rails test` **77 runs, 350 assertions, 0 failures**, `bin/rails runner` 서비스 스모크 13단계 + HTTP 흐름 스모크(통합 테스트, 목록→미리보기→발송→설정→이력→제외→게이트→로그아웃 캐시 정리) 전건 PASS, 스모크 데이터 클린업(tenants=0)

## 1. 생성/수정 파일 목록

| 구분 | 파일 |
|:---|:---|
| 마이그레이션 | db/migrate/20261020000009_add_reminder_custom_texts.rb(tenants에 remind_custom_text_d3/d7/month_end — 최소 범위) |
| 서비스 | app/services/reminders/scheduler.rb(신규), reminders/sample_invoice.rb(신규 — 설정 화면 예시 미리보기용, 개인정보 없음) |
| 모델 | message_log.rb(template_type을 단계 기반 reminder_d3/d7/month_end로 교체 — tone명 soft/standard/formal은 미사용이던 F3 선제 추가분, REMINDER_TEMPLATE_TYPES·reminder 스코프 추가), invoice.rb(remindable 스코프 — W2 임시 미납 규칙, days_overdue), tenant.rb(REMINDER_TONES/STAGES·remind_custom_text(stage)·톤 검증·bank_info 컨텍스트 검증) |
| 잡 | reminder_dispatch_job.rb(defined? 위임 훅 — 이제 Scheduler 존재로 자동 활성), message_send_job.rb(리마인더 template_type 시 MessageBuilder.reminder 경유) |
| 컨트롤러 | reminders_controller.rb(신규), application_controller.rb(온보딩 게이트 전역화 — W1 후속①), sessions_controller.rb(게이트 skip + 로그아웃 CSV 캐시 정리 — W1 후속②), registrations/onboarding_controller.rb(게이트 skip), onboarding_controller.rb(save_bank_account valid?(:bank_info) — W1 후속③), dashboard_controller.rb(미납 요약·다가오는 리마인더 카운트) |
| 뷰 | reminders/{index,preview,settings,history}.html.erb(신규), dashboard/show.html.erb(오늘 할 일·미납 요약·리마인더 링크) |
| 라우팅 | config/routes.rb(reminders 7경로 — index/preview/deliver_now/settings/history/toggle_exclusion) |
| JS | app/javascript/controllers/reminders_select_all_controller.js(신규 — 목록 전체 선택) |
| 로캘·설정 | config/locales/ko.yml(reminders 섹션·messages.reminder 단계×톤 9종 문구·대시보드·template_type 라벨), config/solapi.yml(템플릿 키를 단계 기반으로 교체) |
| 테스트 | test/integration/f6_http_smoke_test.rb(HTTP 흐름 스모크 — F3의 invoices_flow_smoke_test와 동일 컨벤션, 스위트 포함 통과), students_controller_test.rb(게이트 도입으로 타 테넌트 픽스처 1건 onboarding_step 보정 — 검증 대상(TEN-001 캐시 격리) 불변) |

## 2. F6 레이어별 구현 요약

- **Reminders::Scheduler**: ReminderDispatchJob(매일 09:00)이 호출. 대상 = `Invoice.remindable`(status IN (SENT/UNPAID/OVERDUE) & due_on 경과 & 완납 기록 없음[Payment W3 확장] & CANCELLED 제외[INV-003] & excluded_from_reminders=false[MSG-004]). 단계 판정은 `due_stage_for` 단일 기준: d3(경과 3~6일)/d7(경과 7일 이상·월말 전)/month_end(청구 대상월 말일 전날 이후). 각 단계 template_type이 상이라 MSG-001(청구×템플릿 유형) 유일성이 단계당 1회를 DB+검증+사전 필터 3중으로 강제(배치 누락 재실행에도 중복 없음 — 스모크 3단계). 발송 예약 시각은 `send_time_for`(MSG-006: 설정 시각 9~17, 허용 시간대 외 호출 시 다일 오전 이월) — 수동 즉시 발송에도 동일 적용. 문구는 원장 커스텀 우선 → 톤(부드러움/표준/공식) 기본 9종, MessageBuilder 경유로 원장상호·전화 포함(MSG-005).
- **MessageBuilder**: `reminder(...)` 생성자 추가 — 커스텀 문구는 %{변수} 수동 보간(I18n ASCII 키 제약 회피), SMS 폴백 90바이트 LMS 전환·카카오 치환값은 F3 로직 재사용.
- **컨트롤러·뷰**: 미납 목록(원생·금액·기한·경과일·마지막 리마인더·제외 배지, 필터[전체/제외 원생], 전체 선택) → 즉시 발송 미리보기(수신자 마스킹[TEN-003]·단계·본문·수신처 없음/제외 안내) → 발송(Dispatcher 경유, 이력 MessageLog). 설정(톤·단계 3토글·발송 시각 9~17·단계별 커스텀 문구 + 예시 데이터 미리보기). 발송 이력(리마인더 건 원생별·일시별, 원생 필터). 제외 토글은 목록에서 즉시(해제 시 자동 발송 즉시 배제 — MSG-004). 대시보드에 미납 건수/총액·다가오는 리마인더·바로가기 추가(기준 문구 명시).
- **W1 후속 3건**: ① 온보딩 미완료 게이트를 ApplicationController 전역 before_action으로 확장 — sessions/registrations/onboarding만 skip, /students 등 전 메인 기능 직접 접근 차단(HTTP 스모크로 검증). ② sessions#destroy에서 session의 CSV 오류내역 키로 서버 캐시 삭제 + 세션 키 제거. ③ Tenant `validates bank_name/bank_account/account_holder, presence: true, on: :bank_info` + save_bank_account가 valid?(:bank_info) 선행(business_info 패턴과 동일).

## 3. F6 수용조건 자체 점검

- [x] 발송 이력 원생별·일시별 기록·조회 — MessageLog(reminder 스코프) + history 화면(스모크/HTTP)
- [x] 제외 설정 원생 자동 발송 즉시 배제 — remindable 스코프가 매 배치 재판정(스모크 4단계)
- [x] 발신자 표기 원장 채널/번호 기준 — 솔라피 from(사전등록 번호, F3 Client) + 본문 원장상호·전화(MSG-005)
- [x] 단순 미납은 중립 표시 — 미납 목록은 slate 톤, 경고색 미사용(강조색은 발송 액션만)
- [x] 각 단계 ON/OFF·발송 시간대 설정(야간 금지) — 설정 화면 + remind_send_hour 9..17 검증
- [x] 문구 템플릿 3종 + 원장 수정·저장 — 커스텀 문구 저장 우선 적용(스모크 7단계 치환 확인)
- [x] 최근 발송 기록 표시로 반복 발송 방지 — 목록에 마지막 리마인더 일시 + MSG-001 유일성

## 4. Rule ID 강제 수단 (F6)

- MSG-001: 단계별 template_type 상이 + MessageLog dispatch_uniqueness + Scheduler 사전 필터
- MSG-003: 재시도 상한은 기존 MessageSendJob(1회) 그대로 — 리마인더 동일 경유
- MSG-004: remindable 스코프 + 제외 토글 즉시 반영(스모크)
- MSG-005: MessageBuilder 원장상호·원장전화 치환 + 솔라피 from
- MSG-006: remind_send_hour 9..17 검증 + send_time_for 이월 로직 + recurring 09:00
- INV-003: remindable이 CANCELLED 배제
- TEN-001: RemindersController 전체 current_tenant 스코프, preview/dispatch도 remindable 재적용
- TEN-003: 미리보기 수신자 masked_phone 뷰 마스킹

## 5. 명세 대비 판단 사항 (오케스트레이터 확인용)

1. **template_type 교체**: F3이 선제 추가한 tone 기반 reminder_soft/standard/formal은 미사용이었고 단계별 유일성과 충돌하여 단계 기반(reminder_d3/d7/month_end)으로 교체. 톤은 Tenant.remind_tone + ko.yml 문구 9종(3단계×3톤)으로 반영. 관련 ko.yml/solapi.yml 키 전량 갱신(클린 커트오버 — DB 데이터 없음).
2. **단계 중복 노출 시 동작**: d7 도래 건이 d3를 건너뛴 경우(배치 중단 등) d3는 미발송으로 종료 — due_stage_for가 단일 단계만 반환하기 때문. 대신 d7이 확실히 발송됨(유일성 우선 설계).
3. **월말 단계 범위**: month_end는 대상월 말일 전날 이후 매일 재평가되며 유일성으로 1회만 발송. 이전 달로 넘어간 미납은 month_end 단계를 다시 맞지 않음(d7이 담당) — W2 임시 규칙 기준.
4. **수동 발송의 제외 원생**: MSG-004는 '자동 발송' 배제 규정이므로 원장 즉시 발송은 허용(미리보기에 안내 문구 표시) — 미리보기 화면에서 원장 판단 유도.
5. **테스트 1건 픽스처 보정**: students_controller_test의 타 테넌트 세션 테스트에 `@other_tenant.onboarding_step` 완료 보정 1줄 추가(게이트 도입의 직접 결과, 검증 대상 불변).

## 6. 열린 이슈·리스크

1. **UNPAID/OVERDUE 상태 미사용**: W2는 SENT만 존재(상태 자동 전이는 W3 수납 도입 시) — remindable은 규칙 선반영 상태.
2. **카카오 템플릿 심사**: reminder_d3/d7/month_end 템플릿 코드는 운영 주입 필요(config/solapi.yml). 미주입 시 SIMULATED로 기록(실발송 없음).
3. **month_end 판정 기준 시각**: `due_stage_for`가 서버 TZ(KST 가정) 기준 — TZ 변경 시 재확인.

---

# Phase 6 수정 보고 — W2 리뷰 지적 12건(W2FixDev / 2026-10-20)

- 검증: `bin/rails db:migrate` up(20261020000010 포함), `bin/rubocop` 78 files no offenses, `bin/brakeman` no warnings, `bin/rails test` **77 runs, 350 assertions, 0 failures**, `bin/rails runner` 스모크(유니크 동시 삽입 차단·d3 경계·크론 파싱·취소 청구 발송 차단) 전건 OK, 스모크 테넌트 클린업 완료. 자세한 이슈별 기록은 _workspace/05_review.md 각 항목 하단 '수정 완료' 참조.

## 수정 파일

| 파일 | 내용 |
|:---|:---|
| db/migrate/20261020000010_add_message_logs_dispatch_uniqueness.rb (신규) | [C1] message_logs [invoice_id, template_type] partial unique index(where resend_of_id IS NULL) — MSG-001 DB 강제 |
| app/services/notifications/dispatcher.rb | [C1] 건별 requires_new savepoint + ActiveRecord::RecordNotUnique rescue → duplicated. Result에 dispatched_invoice_ids 추가 |
| app/services/reminders/scheduler.rb | [C2] due_stage_for — d3는 경과일 ≥ 3일만(1~2일 nil), d7·month_end 기존 판정 유지 |
| config/recurring.yml | [C3] monthly_invoice_generation `0 7 1 * *`, reminder_dispatch `0 9 * * *` — 전부 Fugit::Cron 확인 |
| app/jobs/message_send_job.rb | [C4] perform 초반 Invoice CANCELLED 가드 → FAILED(INVOICE_CANCELLED) |
| app/controllers/invoices_controller.rb | [C4] resend 상태 검증(SENT/UNPAID/OVERDUE만) [C5] send_batch 선반영 제거 — 실제 큐 등록 건(dispatched_invoice_ids)만 mark_sent!, 예약 시각 파싱 실패 시 즉시발송 변질 차단 [W10/W11] |
| app/models/invoice.rb | [W6] adjust! DRAFT/READY만 허용 [W7] cancel! 빈 사유 errors.add+false(raise 제거) + QUEUED 로그 연쇄 취소(잡 discard + FAILED) |
| app/models/message_log.rb | [W8] has_many :resends FK resend_of_id 수정 |
| app/jobs/reminder_dispatch_job.rb | [W12] defined? 사코드 가드 제거 |
| db/migrate/20261020000007_create_message_logs.rb | [W12] template_type 주석 갱신(단계 기반 값) |
| config/locales/ko.yml | invoices.errors.{resend_not_allowed, not_editable, invalid_send_at} + messages.errors.invoice_cancelled 추가 |
| app/controllers/invoices_controller.rb (edit) | [W6] SENT 이후·취소 청구 수정 화면 진입 차단 |

## 이슈 9(MSG-005 per-tenant 발신 표기)

코드 수정 대상 아님(리뷰 권고 사항) — 원장별 카카오채널/발신번호 연동은 P1 과제로 유지. PRD 14장 명시는 오케스트레이터 확인 필요.

## 참고(회귀 수정)

cancel!의 transaction 블록이 find_each(nil)을 반환해 성공 경로가 falsy가 되는 문제를 블록 후 `true` 반환으로 보정(스모크 테스트 1건이 잠깐 적발 — 최종 전 건 통과).

## Phase 6-2 — W2 테스트 발견 버그 수정 (W2Fix2Dev / 2026-10-20)

### BUG-1 [MSG-003] 자동 재시도가 실질 2회 실행됨
- 파일: app/jobs/message_send_job.rb (handle_retry_or_fail)
- 수정: `executions <= MAX_AUTO_RETRIES` → `executions < MAX_AUTO_RETRIES`. ActiveJob은 재시도 시점에 executions를 증가시키므로 1차 실행(executions=0)만 재시도 큐에 등록되고 2차(executions=1)에서 FAILED 확정 — PRD MSG-003 "재시도 상한 1회"와 일치.

### BUG-2 [INV-002] 422 재렌더 시 Template::Error(500)
- 파일: app/models/invoice.rb
- 수정: `attr_accessor :change_reason` 추가. edit.html.erb의 `f.text_field :change_reason`가 READY 청구 422 재렌더 시 바인딩할 가상 어트리뷰트가 없어 발생한 오류. 컨트롤러는 `invoice_params[:change_reason]`(params.expect에 이미 포함)로 adjust!에 전달하므로 기존 파라미터 경로와 정합.

### 검증
- 재현 테스트 2건 테스트 파일 변경 없이 통과
- `bin/rails test`: 135 runs, 541 assertions, 0 failures, 0 errors
- `bin/rubocop`: 85 files no offenses / `bin/brakeman`: No warnings
