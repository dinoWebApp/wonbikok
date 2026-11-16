# 03_implementation.md — F5 현금영수증 발행 (바로빌 연동) 구현 결과

- 실행일: 2026-11-16 / 담당: wonbikok-developer-lite
- 게이트: `bin/rubocop` 0 offense · `bin/brakeman` 0 warning · `bin/rails test` **214 runs, 890 assertions, 0 failures 0 errors** (기존 170건 회귀 없음 + 신규 +44건)

## 1. 변경 파일 목록

### 신규 (13)
| 구분 | 파일 |
|---|---|
| 마이그레이션 | `db/migrate/20261116000001_add_cash_receipts.rb` |
| 모델 | `app/models/cash_receipt.rb` · `app/helpers/cash_receipts_helper.rb` |
| 어댑터 | `app/services/barobill/base_service.rb` · `app/services/barobill/cash_receipt_service.rb` · `app/services/barobill/member_service.rb` |
| 도메인 | `app/services/cash_receipt/triggerable.rb` · `app/services/cash_receipt/cancel_service.rb` · `app/services/cash_receipt/notifier.rb` |
| Job | `app/jobs/cash_receipt/issue_job.rb` · `app/jobs/cash_receipt/sync_job.rb` |
| 컨트롤러·뷰 | `app/controllers/cash_receipts_controller.rb` · `app/views/cash_receipts/{index,show,cancel_form}.html.erb` |
| 테스트 | `test/models/cash_receipt_test.rb` · `test/services/cash_receipt_triggerable_test.rb` · `test/services/barobill_services_test.rb` · `test/jobs/cash_receipt_issue_job_test.rb` · `test/jobs/cash_receipt_sync_job_test.rb` · `test/controllers/cash_receipts_controller_test.rb` |

### 수정 (최소·추가만)
- `db/schema.rb` — cash_receipts·tenants/guardians/students 추가 컬럼 반영
- `config/routes.rb` — cash_receipts 블록 추가만
- `config/locales/ko.yml` — cash_receipts·barobill·messages.template(2키)·activerecord 속성·검증 메시지 추가(기존 키 불변)
- `app/models/invoice.rb` — `cash_receipt_issuable?` 메서드 추가(CR-002 판정)
- `app/models/tenant.rb` — cash_receipts 연관 + biz 필드 business_info 컨텍스트 검증 추가
- `app/models/guardian.rb` — `encrypts :business_number` + 형식 검증(TEN-003)
- `app/models/student.rb` — cash_receipt_issue_type enum 추가
- `app/models/message_log.rb` — template_type 2종 추가(cash_receipt_issued/failed)
- `app/controllers/onboarding_controller.rb` — step2(사업자 정보)에 biz 필드 수집 + RegistCorp 시도(실패 차단 없음)
- `app/views/onboarding/step2.html.erb` — 필드 3종 추가
- 테스트 갱신: `tenant_test`(business_info 완비 케이스에 신규 필수 필드)·`onboarding_controller_test`(신규 필드 파라미터 + RegistCorp 2건)

## 2. 마이그레이션 요약

- `cash_receipts`: tenant_id·invoice_id(NN)·payment_id(예약)·**mgt_key(24, 유니크 인덱스 = CR-001 DB 강제)**·cancel_mgt_key·issue_type(기본 income_deduction)·state(기본 pending)·barobill_state(int)·nts_confirm_num(9)·nts_confirm_message·identity_num(**암호화**)·trade_date·amount·tax·service_charge·item_name·issued_at·cancelled_at·cancel_reason·retry_count·last_error·issued_by. 인덱스 [tenant_id, state]·[invoice_id]
- `tenants`: biz_tel·biz_type(업태)·email·barobill_member_id·barobill_joined_at — RegistCorp 필수 수집(PRD 10.2). 사업자번호는 기존 business_number 재사용(신규 컬럼 없음)
- `guardians`: business_number(암호화) / `students`: cash_receipt_issue_type(기본 income_deduction)

## 3. 바로빌 어댑터 구현 결정

- **통신**: SOAP 1.1 직접 HTTP(Net::HTTP POST `text/xml`, SOAPAction 헤더, `{host}/CASHRECEIPT.SVC`). savon 미채택(Ruby 4 호환 미확인)
- **엔벨로프**: `<soap:Envelope xmlns:ns="http://ws.baroservice.com/"><soap:Body><ns:{Method}>파라미터 순서 보관</ns:{Method}>`. 응답은 `local-name()='{Method}Result'` 추출, 음수 → failure(code·i18n 메시지). 복합형(CashBillEx)은 RawXml 래퍼로 자식 요소 직렬화(escape 회피)
- **환경 분기**: production=release_auth_key+ws.baroservice.com / 그 외=test_auth_key+testws.baroservice.com. **dev/test는 기본 SIMULATED 강제 — 실호출은 `BAROBILL_LIVE=1` 환경변수로만 허용**(credentials에 키가 등록되어 있어도). cert_key 공백 시에도 SIMULATED
- **SIMULATED**: 외부 호출 없이 발행=1·상태=3000(승인번호 SIMUL3000)·취소=1·조회URL 반환. 단위 테스트에서 forbid_network 스텁으로 "SIMULATED 시 네트워크 0회" 방어 검증
- **메서드 매핑**: RegistAndIssueCashBill / GetCashBillInfo(상태+NtsconfirmNum 파싱) / CancelCashBillEx·CancelCashBillPartialEx / GetCashBillMailURL(NK) / CheckCorpIsMember·RegistCorp(-32000 기가입 = 성공 간주)
- **CashBillEx 필수 검증**: 어댑터 진입 전 사전 검증(Tel 누락 등 → 외부 호출 없이 failure)
- ⚠️ 스파이크 검증 필요: 메서드별 파라미터 순서·CashBillEx 자식 태그명·GetCashBillInfo 응답 필드명(NtsconfirmNum)·CASHRECEIPT.SVC 엔드포인트 접미사 — 공식 문서 페이지가 JS 렌더라 기계 열람 불완전. 스텁 XML 구조는 "메서드Response > 메서드Result" 규격 기준

## 4. 도메인 로직 (Rule ID 매핑)

| Rule | 강제 수단 |
|---|---|
| CR-001 | mgt_key 파생(CR{invoice_id}{YYYYMM}{ID/EE}=14자) + 모델 uniqueness + DB 유니크 인덱스 + Triggerable skip. 테스트: 검증·DB RecordNotUnique·재트리거 skip |
| CR-002 | `Invoice#cash_receipt_issuable?`(SENT/UNPAID/OVERDUE만, CANCELLED 제외) → Triggerable 진입 검사. F4 연결 시 Payments::ConfirmService가 `CashReceipt::Triggerable.trigger_issue_for(invoice, issued_by:)` 호출 |
| CR-003 | issued 전이는 processing 상태에서만 + barobill_state 3000 확인 시에만(`mark_issued!` 가드). IssueJob은 요청 성공해도 SyncJob 폴링으로만 확정 |
| CR-004 | IssueJob 실패 시 재시도 전 `state(mgt_key)` 재조회 — 3000이면 failed 표시 없이 폴링 확정 |
| CR-005 | CancelService: 사유 필수(422) → cancel_pending + CancelMgtKey("CRC"+원본) → 실패 시 issued 복원·last_error, 성공은 SIMULATED 즉시 cancelled / 실환경 7000 폴링 확정 |
| CR-006 | 재시도 1회 한도 → 소진 시 failed + `CashReceipt::Notifier.notify_failure`(MessageLog SIMULATED 기록) |
| TEN-001 | 컨트롤러 전 경로 current_tenant 스코프 — 타 테넌트 404(테스트) |
| TEN-002 | identity_num 13자리 숫자 검증 거절 + 수집 필드 부재(휴대폰/사업자번호만) |
| TEN-003 | encrypts identity_num·business_number, `masked_identity_num`(뒤4자리), 암호문 저장 테스트(raw SQL) |
| MSG | MessageLog template_type 확장 + dispatch 유일성 검증 재사용, issued 확정 시 cash_receipt_issued 1회 |

## 5. 상태 머신 (9.2)

needs_info ←(식별번호 미비) 트리거 → pending →(IssueJob) processing →(SyncJob 3000) issued →(CancelService) cancel_pending →(7000) cancelled / processing→4000→failed→(수동 retry→pending, retry_count++) / 발행 요청 실패+기발행(3000 재조회)→processing 유지

## 6. 테스트 목록 (44건 신규)

- 모델(10): mgt_key 파생·중복 검증·DB 유니크 / CR-003 가드 / D-1 TradeDate / TEN-002 / TEN-003 암호문·마스킹 / 소득공제·지급증명 수취인 결정·needs_info / retryable·cancellable
- Triggerable(4): 수동 트리거 생성+enqueue / CR-001 skip / CR-002 차단(DRAFT·CANCELLED) / needs_info 비큐
- IssueJob(5): SIMULATED processing 유지+SyncJob 예약 / 전체 플로우 issued(3000·SIMUL3000) / CR-004 기발행 재조회 / CR-006 1회 재시도 유지·소진 시 failed+알림
- SyncJob(5): 3000 issued+안내 1회 / 4000 failed+사유 / 7000 cancelled / 2500 processing 유지 / 확정 상태 비폴링
- 어댑터(10): SIMULATED 분기(네트워크 0회 방어)·필수 필드 사전 차단·스텁 XML 성공/음수/복합형(NtsconfirmNum) 파싱·엔벨로프 규격·환경 키 선택·RegistCorp -32000
- 컨트롤러(8): TEN-001 목록 미노출·상세 404 / 수동 발행·중복 안내 / failed-only 재발행 / 취소 422(사유 공백)·취소 성공(즉시 cancelled·CancelMgtKey)·취소 폼 issued 전용
- 온보딩(+2): RegistCorp 성공(member_id·linked) / 실패 시 온보딩 계속(member_id nil·failed)

## 7. 남은 리스크·운영 과제

1. **SOAP 규격 스파이크 전제** — §3 경고 항목. 스파이크 시 `BAROBILL_LIVE=1 bin/rails runner`로 RegistCorp→발행→GetCashBillInfo 1회 확인 후 어댑터 파라미터 정합화 필요
2. 알림톡 cash_receipt_issued 템플릿 카카오 심사 전까지 SIMULATED 기록(MessageSendJob 미연결) — 심사 후 Notifier를 SendAlimtalkJob 경유로 전환
3. RegistCorp ID/PWD 자동 생성 — pwd는 미보관(파트너 포털 관리), member_id만 tenants 저장. ID/PWD 영구 보관 정책 확정 필요
4. 부분 취소 UI 미제공(CancelService.partial_cancel 경로만 구현) — F4 오체크 정정 연계 시 화면 추가
5. 발행 이력 CSV/PDF 내려받기·외부 발행 수동 기록은 F5 명세의 P1/선택 항목 — 미구현
6. 학부모 조회 URL(GetCashBillMailURL)은 어댑터만 구현 — 노출 위치는 F9 학부모 청구 링크 연계 시

## 8. 스파이크 실행에 필요한 입력

- 원비콕 자체 사업자등록번호·상호·대표자명·주소·업태·사업장 전화·대표자 이메일(RegistCorp용)
- credentials barobill.test_auth_key 실제 값 존재 확인(이미 등록됨 — 미조작)
- 스파이크 절차: `BAROBILL_LIVE=1 bin/rails runner` → MemberService.regist_corp(테스트키) → CashReceiptService.regist_and_issue(테스트 mgt_key) → state 3000 확인 → 어댑터 규격 불일치 시 파라미터 수정

## 9. Phase 6 수정 (리뷰 지적 반영 — 05_review.md)

- 게이트: `bin/rubocop` 0 offense · `bin/brakeman` 0 warning · `bin/rails test` **229 runs, 947 assertions, 0 failures 0 errors** (1차 214건 회귀 없음 + 신규 +15건)

### BLOCKER
- **B1(CR-006)** — `app/jobs/cash_receipt/issue_job.rb:15`: 부재 메서드 `reschedule_sync!` → `CashReceipt::SyncJob.perform_later(receipt.id)` 교체. 스텁 없는 실제 `retry_job` 2회째 수행 통합 테스트 추가(`perform_enqueued_jobs` 경유 — 수정 전에는 NoMethodError 크래시 재현, 수정 후 processing 유지·SyncJob 재예약 확인)
- **B2(연습 모드)** — `Barobill::CashReceiptService.from_credentials_with_tenant`에서 `tenant.practice?`면 cert_key 공백 강제(IssueJob·SyncJob·CancelService·조회 재시도 전 경로가 본 빌더 경유 — W2 `message_send_job.rb:69` 선례 준용). 테스트: practice 테넌트 + cert_key 스텁 + `post_xml` 네트워크 호출 시 예외 래핑으로 **네트워크 0회·SIMUL3000 기록** 검증(issue/sync/controller cancel 3건)

### CRITICAL
- **C1(CR-003/007)** — `sync_job.rb`: 비종결(1000/2000/2500)·폴링 실패 시 `POLL_WAITS`(30s→1m→5m→10m) 단계 증가 재예약, `MAX_POLLS=6` 상한 초과 시 재예약 중단 + 로그 경보(무한 루프 방지). 테스트: 2500 재예약 / 폴링 실패 재예약·상한 중단
- **C2(CR-005)** — `cancel_service.rb`: 어댑터 `Barobill::Error` raise 시 rescue → 기존 실패 분기와 동일(issued 복원·last_error 기록·failure Result). 컨트롤러 500·cancel_pending 고착 방지. 테스트: 취소 중 네트워크 오류 → 422·issued 복원
- **C3(CR-002)** — `invoice.rb`: `cash_receipt_issuable?(origin:)` — auto=PAID·PARTIALLY_PAID 필수, manual=CANCELLED만 차단. `Invoice` enum에 PAID·PARTIALLY_PAID 키 선활성화(F4 연계 전이 로직은 F4 착수 시). `trigger_issue_for(invoice, issued_by:, origin: :manual)` 시그니처. 테스트: auto UNPAID 차단·PAID/PARTIALLY_PAID 허용, manual DRAFT 허용·CANCELLED 차단
- **C4(TEN-003)** — `cash_receipt.rb`: `issued_by=` 오버라이드로 휴대폰번호 형식 입력 마스킹 저장(`010-****-4444`) — 원문 저장 원천 차단(경로 무관). 상세 화면은 저장값(마스킹) 렌더. 테스트: 모델·컨트롤러 각 1건(raw SQL로 컬럼 원문 부재 검증)
- **C5(월별 조회)** — `set_month`: `/\A\d{4}-\d{2}\z/` 형식 검증 기반 수용(무효·공백만 당월 기본) — 과거 월 이력 조회 가능. 테스트: 2026-09 이력 조회·무효 파라미터 당월 폴백
- **C6(9.2 상태 머신)** — `retryable?` = failed·needs_info. retry 액션에서 needs_info 건은 `resolve_identity_num!` 재수행 → pending 복귀 시 IssueJob 재큐, 미보완 시 needs_info 유지 안내. 테스트: 보완 후 재발행·미보완 유지 2건

### WARNING
- **W1** — TradeDate D-1 검증을 데드 컨텍스트 `on: :issue` → `on: :create`로 전환(생성 시 항상 적용, 갱신 시 비적용으로 재시도 회귀 방지). 테스트 갱신
- **W2** — `sync_job.rb` 3000 분기: `mark_issued!` 반환값 검사 — 가드 실패(cancel_pending에서 3000 폴링) 시 알림 미실행. 테스트 추가
- **W6** — `triggerable.rb`: create!의 모델 유니크 검증(RecordInvalid)·DB 인덱스(RecordNotUnique) 양쪽 rescue → 중복이면 승자 건 duplicate 응답 통일, 중복 아닌 검증 실패는 원 예외 유지. 테스트: find_by 1회 nil 스텁으로 레이스 재현
- **W8** — `base_service.rb resolve_cert_key`: production에서 release_auth_key 누락 시 SIMULATED 전환을 `Rails.logger.warn` 경보로 감지 가능화

### 문서화만 (코드 수정 없음 — 후속 과제 등록)
- **W3(CR-006 이중 알림)**: 푸시 채널 부재 — 알림톡 cash_receipt_issued·failed 템플릿 카카오 심사 통과 후 Notifier를 MessageSendJob(Solapi) 경유로 전환할 것. 현재는 MessageLog SIMULATED 기록(§7-2와 동일 과제)
- **W4(CR-007 서비스 상태 배너)**: 바로빌 장애 시 원장 화면 배너·복구 알림(10.4)은 미구현 — C1의 폴링 상한 로그 경보를 트리거로 하는 모니터링 연계를 W4 대시보드(F7) 착수 시 과제로 등록
- **W5(partial_cancel 상한)**: 부분 취소 금액이 스냅샷 amount 이하인지의 서버 검증은 F4 오체크 정정 연계 시 CancelService 진입 검증으로 추가(F4 전 과제)
- **W7(RegistCorp 동기 SOAP)**: onboarding step2의 RegistCorp 요청 스레드 동기 SOAP(open 5s/read 20s)는 Job 분리 또는 타임아웃 단축이 바람직 — 온보딩 UX 개선 시 후속 과제

## 10. Phase 6 2차 수정 (05_review.md "2차 리뷰" R1·R2 반영)

- 게이트: `bin/rubocop` 0 offense · `bin/brakeman` 0 warning · `bin/rails test` **230 runs, 958 assertions, 0 failures 0 errors** (Phase 6 1차 229건 유지 + 시나리오 교체/추가)

### R1(CR-005) — cancel_pending 폴링 고착 해소
- `app/jobs/cash_receipt/sync_job.rb` 3000 분기: `mark_issued!` 가드 실패 시 `receipt.cancel_pending?`이면 `reschedule_poll` 수행 — 취소 요청 직후 첫 폴링(원본 아직 3000)에서 중단되지 않고 7000 확정까지 폴링 지속(MAX_POLLS 상한 유지)
- 테스트 교체: W2 테스트("가드 실패 후 종료"를 정상으로 고정) → cancel_pending 3000 폴링 = 알림 미실행·재예약 확인 → 이어서 7000 폴링 = cancelled 확정(고착 없음) 시나리오로 교체

### R2(CR-006) — 재시도 2회째 실제 재발행
- `app/jobs/cash_receipt/issue_job.rb` `handle_failure` 재시도 분기: `state: :pending` 복귀 후 `retry_job` — 2회째 실행이 processing 가드(라인 16)를 우회해 `mark_processing!` 경유로 실제 재발행을 수행하고, 소진 시 `mark_failed!`+`Notifier.notify_failure` 분기에 도달(CR-006 충족)
- 테스트 교체(실제 플로우 정합판):
  ① B1 테스트("processing 유지를 성공으로 고정") → 1회 실패→재시도→2회째 발행 성공 = issued 확정(perform_enqueued_jobs 실제 retry_job 경유)
  ② 1회 실패→재시도→2회째 재실패 = failed + 원장 알림(MessageLog cash_receipt_failed +1)
  ③ "실패 1회째" 단위 테스트도 pending 복귀 기준으로 갱신

### 경미 — retry 문구 통합 표현
- `config/locales/ko.yml`: retry_button "다시 발행하기"→"다시 시도하기", retry_confirm → "수취인 정보 보완 또는 발행 실패 건을 다시 시도할까요? …" (needs_info 건 retry 노출 대응)

### W-N 문서화 (코드 수정 없음 — F4 착수 시 정책 확정 과제)
- **W-N1**: manual 게이트가 DRAFT·READY까지 허용 — UI 주석("발송 완료 이후의 유효 청구")과 불일치. DRAFT는 금액 수정 상태라 TEN-004 스냅샷 위험이 있어 최소 READY 이상 제한 여부를 F4 착수 시 정책 확정할 것(현재는 리뷰 지시에 따라 CANCELLED만 차단 유지)
- **W-N2**: auto+PARTIALLY_PAID 트리거 시 amount가 total_amount(전액) 스냅샷 — 부분납 건의 발행 여부·금액 기준(수납액 기준 vs 전액 기준)은 F4(Payment) 착수 시 정책 확정 후 스냅샷 산정 수정 필요
