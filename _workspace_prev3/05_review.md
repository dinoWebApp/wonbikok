# 05_review.md — F5 현금영수증(바로빌 연동) 코드 리뷰 (Phase 5, 1차)

- 실행일: 2026-11-16 · 프로필: wonbikok-reviewer-lite · 판정: **CHANGES_REQUESTED**
- BLOCKER 2 · CRITICAL 6 · WARNING 8 — Phase 6에서 BLOCKER·CRITICAL 전건 + 선별 WARNING 수정 후 재리뷰

# BLOCKER (즉시 수정)

[B1] CR-006/런타임 에러 — app/jobs/cash_receipt/issue_job.rb:15
  `reschedule_sync!` 메서드가 정의되어 있지 않음(파일 전체·app/ grep 확인).
  processing 상태로 IssueJob이 재실행되면 NoMethodError로 Job 크래시.
  CR-006 자동 재시도의 실제 2회째 수행에서 반드시 통과: 1회째 실패 → retry_job(processing 유지,
  :74-82) → 30초 후 2회째 실행 → 라인 15 분기 → 크래시 → 영수증 processing 고착.
  테스트가 executions/lookup_existing_state를 스텁(issue_job_test.rb:26-35)해 미검출.
  수정: 라인 15를 `CashReceipt::SyncJob.perform_later(receipt.id)`로 교체 + 스텁 없는 실제
  retry_job 경로 통합 테스트 추가.

[B2] 연습 모드 실발행 금지 위반 — app/services/cash_receipt/triggerable.rb 전체·
  app/jobs/cash_receipt/issue_job.rb·cancel_service.rb에 tenant.practice? 검사 부재.
  SIMULATED 판정이 전역 cert_key 환경 분기(base_service.rb:58-64)뿐이라, production에서
  연습 모드 테넌트의 수동 발행/취소가 실제 바로빌 호출(과금·국세청 신고)로 이어짐.
  PRD 14장 W3 확정: "연습 모드·연동 키 미설정 시 발송은 SIMULATED로 기록한다" — 키 미설정만 구현됨.
  W2 선례: message_send_job.rb:69 `return true if log.tenant.practice?`.
  수정: IssueJob·SyncJob·CancelService에 practice? → SIMULATED 강제 분기 + 연습 모드
  실호출 방지 테스트(네트워크 0회).

# CRITICAL (수정 후 통과)

[C1] CR-003/CR-007 — app/jobs/cash_receipt/sync_job.rb:39·43-46
  폴링이 1회성. 2000/2500(정상 경로)이거나 폴링 실패 시 processing/cancel_pending에 머른 뒤
  재폴링 예약 없음 → 실환경 issued 확정·학부모 안내 영구 지연. "완료 시 자동 갱신" 미충족.
  수정: 비종결 상태면 SyncJob 재예약(wait: 단계 증가) 또는 processing/cancel_pending 정기 스캔.

[C2] CR-005 — app/services/cash_receipt/cancel_service.rb:24-31
  service.cancel/partial_cancel은 오류 시 Barobill::Error를 raise — CancelService·컨트롤러에
  rescue 없어 500 + cancel_pending 고착. 수정: rescue Barobill::Error → issued 복원·
  last_error 기록·failure Result(기존 실패 분기와 동일 처리).

[C3] CR-002 — app/models/invoice.rb:113-115 (cash_receipt_issuable?)
  게이트 방향이 규칙과 반대. (a) PAID(입금 확인 완료) 청구가 제외되어 F4 연결 지점에서
  자동발행 차단. (b) UNPAID/OVERDUE(수납 미확인) 발행 허용 — CR-002 정면 위반.
  수정: `trigger_issue_for(invoice, origin: :auto|:manual)` — auto는 수납 확인(PAID/
  PARTIALLY_PAID) 필수, manual은 CANCELLED만 차단. 인터페이스 시그니처 정리.

[C4] TEN-003 — app/controllers/cash_receipts_controller.rb:32 + show.html.erb:36
  `issued_by`에 `current_user.phone_number` 평문 저장(encrypts 복호화 값이 비암호화 컬럼에)
  + 상세 화면 원문 렌더. 수정: user_id 또는 마스킹 값 저장. 처리자·시간 기록 요구 유지.

[C5] F5 명세(월별 조회) — app/controllers/cash_receipts_controller.rb:72-74
  `params[:month].presence_in([당월])` — 당월 외 입력 전부 당월 강제 → 과거 월 이력 조회 불가
  (5년 보관 요건 충돌). 수정: `/\A\d{4}-\d{2}\z/` 형식 검증 기반 월 수용(기본 당월).

[C6] 9.2 상태 머신 — needs_info 복귀 경로 부재
  needs_info가 터미널 취급(issue_job.rb:36)·retry는 failed 전용 → 정보 보완 후 재시도 불가,
  발행 불가 고착. 수정: needs_info 건 resolve_identity_num! 재수행+IssueJob 재큐 경로
  (수동 버튼 또는 retry 확장) 추가.

# WARNING (권장 — W1·W2·W6은 이번 수정에 포함, W3·W4·W5·W7·W8은 문서화/후속)

[W1] TradeDate D-1 검증이 `on: :issue` 컨텍스트 전용(cash_receipt.rb:35) — 사용처 없는 데드
  가드. IssueJob 제출 전 검증 또는 always 컨텍스트 전환. → **포함**
[W2] sync_job.rb:24-28 — 3000 분기가 mark_issued! 반환값 무시. cancel_pending에 3000 폴링 시
  가드로 무력화되지만 notify_issued 실행. 반환값 검사로 알림 조건 정리. → **포함**
[W3] CR-006 이중 알림 — 푸시 채널 부재(알림톡 SIMULATED만). 템플릿 심사 후 MessageSendJob
  전환 과제로 문서화. → 문서화
[W4] CR-007 서비스 상태 배너·복구 알림 미구현(10.4) — 범위 밖이면 계획 문서 명시. → 문서화
[W5] cancel_service partial_cancel amount 상한(스냅샷 amount 이하) 서버 검증 없음 — F4 연계
  전 추가 권장. → 문서화(후속)
[W6] triggerable.rb:20-36 — find_by→create! 레이스 시 RecordNotUnique 500. rescue 후 duplicate
  응답 통일 권장. → **포함**
[W7] onboarding register_barobill_member — 요청 스레드 내 동기 SOAP(open 5s/read 20s). Job
  분리 또는 타임아웃 단축 권장. → 문서화(후속)
[W8] production에서 release_auth_key 누락 시 조용히 SIMULATED — 전환 감지 로그/경보 권장.
  → **포함(로그 경보 1줄)**

# 체크리스트 적합 (수정 불필요)

CR-001 멱등 3중 방어(mgt_key 파생+모델 유니크+DB 인덱스+skip) / CR-003 3000 한정 mark_issued!·
2000 오매핑 없음 / CR-004 재조회 골격 / TEN-001 격리 / TEN-002 주민번호 거절·10자리 사업자번호
강제 / TEN-003 encrypts+암호문 저장 테스트+마스킹 / TEN-004 스냅샷 / SIMULATED·BAROBILL_LIVE
게이트·키-엔드포인트 쌍·네트워크 0회 방어 테스트 / SOAP 음수 오류코드 래핑·타임아웃(5/20s)·
strict 파싱 / 아키텍처(네임스페이스·얇은 컨트롤러·i18n 전용·Turbo 422/303·44px·16.2 배지) /
회귀(기존 파일 추가 위주·테스트 약화 없음·data-* 유지)

# 테스트 제안 (Tester 전달 — Rule ID)

- CR-006: 스텁 없는 retry_job 2회째 수행 통합 테스트(B1)
- 연습 모드: practice 테넌트 issue/retry/cancel 네트워크 0회 + SIMULATED 기록(B2)
- CR-003: 2500 폴링 → 재폴링 → 3000 issued(C1)
- CR-005: 취소 중 네트워크 오류 → issued 복원·last_error(C2)
- CR-002: auto 트리거 PAID 허용·UNPAID 차단, manual 정책 분리(C3)
- TEN-003: issued_by 저장값에 휴대폰번호 원문 없음(C4)
- F5 명세: 과거 월 이력 조회(C5), needs_info 보완 후 재발행(C6)

## 2차 리뷰 (Phase 6 수정 검증 — 2026-11-16)

상태: CHANGES_REQUESTED (BLOCKER 0 · CRITICAL 2 · WARNING 2 + 경미 1)

### 수정 확인 완료 (근거)
- [B1] issue_job.rb:16 — reschedule_sync! → CashReceipt::SyncJob.perform_later 교체 확인.
  retry_job 2회째 실수행 테스트(:133-144)로 크래시 재현 제거 확인. 단, 아래 R2 참조.
- [B2] cash_receipt_service.rb from_credentials_with_tenant:31-32 — practice? → cert_key "" 강제
  확인. IssueJob·SyncJob·CancelService 모두 본 빌더 경유 → 실발행·실취소·실폴링 전 차단.
  practice 테넌트 네트워크 0회 테스트 3건(issue:146/sync:132/controller:137) 확인.
  MemberService(온보딩)는 practice 선정(step5) 이전 step2에서만 호출 — 범위 외 수용.
- [C1] sync_job.rb:10-11·44-63 — POLL_WAITS 단계 증가 재예약·MAX_POLLS=6 상한·poll_count 전달
  확인. 2500 재예약·폴링 실패 재예약·상한 중단 테스트 확인. 단, 아래 R1 참조.
- [C2] cancel_service.rb:29-39 — rescue Barobill::Error → failure Result 균일화, issued 복원 확인.
- [C3] invoice.rb:116-121(origin 게이트)·triggerable.rb — auto=PAID·PARTIALLY_PAID 필수,
  manual=CANCELLED만 차단. 방향 전환 확인, Invoice enum 키 선활성화는 추가 위주.
- [C4] cash_receipt.rb:100-104 — issued_by= 오버라이드로 휴대폰 형식 입력 마스킹 저장(원천 차단).
- [C5] controller set_month:82-84 — 형식 검증 기반 월 수용 확인.
- [C6] cash_receipt.rb:95-97(retryable?=failed·needs_info) + controller retry:43-50 —
  resolve_identity_num! 재수행 → pending 복귀 시 재큐. 9.2 복귀 경로 완성.
- [W1] on: :issue → on: :create 전환 확인. / [W2] mark_issued! 반환값 검사 확인(테스트 :119-130).
- [W6] RecordNotUnique·RecordInvalid rescue → duplicate 통일, 비중복 검증 실패는 원 예외 재raise 확인.
- [W8] production SIMULATED 전환 warn 경보 확인.
- 회귀: 기존 적합 항목 약화 없음 — 수정은 분기 추가·가드 보강 위주.

### 잔여 CRITICAL (수정 후 재검증 필요)

[R1] CR-005 잔여 — app/jobs/cash_receipt/sync_job.rb:29-33
  cancel_pending 건이 3000으로 폴링되면 mark_issued! 가드 실패 후 apply_state가 재예약 없이 종료.
  취소 요청 직후 첫 폴링은 원본 상태가 아직 3000일 가능성이 높아 폴링 즉시 중단 → 7000 확정 불가
  → cancel_pending 영구 고착(복구 경로 없음). 수정: 가드 실패 시(최소한 cancel_pending일 때)
  reschedule_poll 수행. W2 테스트(:119-130)가 이 동작을 "정상"으로 고정 — 함께 갱신.

[R2] CR-006 잔여 — app/jobs/cash_receipt/issue_job.rb:16·68-83
  processing 가드(라인 16)가 "제출 성공 후 폴링 대기"와 "실패 후 재시도 예약"을 구분하지 못해
  재시도 2회째 실행이 재발행 없이 SyncJob 예약만 하고 종료. 결과: (a) mark_failed! +
  Notifier.notify_failure 분기 도달 불가 — CR-006 재시도 소진 시 failed+알림 미충족.
  (b) 제출 전 실패는 폴링 6회 전부 실패 → 상한 중단 → processing 영구 고착(수동 재발행도 불가).
  B1 테스트(:133-144)가 이 동작을 성공 기준으로 삼음, :123-131은 상태 조합 불일치 — 교체 필요.
  수정(권장): handle_failure 재시도 분기에서 state: :pending 복귀 후 retry_job — 2회째가
  mark_processing! 경유로 실제 재발행 수행, 소진 시 failed+알림 도달.

### 신규 WARNING (문서화 수준)

[W-N1] manual 게이트가 DRAFT·READY까지 허용 — UI 주석("발송 완료 이후의 유효 청구")과 불일치.
  DRAFT는 금액 수정 상태라 TEN-004 스냅샷 위험. 최소 READY 이상 제한 권장(정책 문서화 대안 수용).
[W-N2] auto+PARTIALLY_PAID 시 amount가 total_amount(전액) 스냅샷 — 부분납 발행 여부·금액 기준은
  F4 착수 시 정책 확정 필요. 문서화.
[경미] show.html.erb retry_confirm 문구가 "발행 실패 건" 전용 표현 — needs_info 건에도 노출.
  문구 분기 또는 통합 표현 권장.

### 판정
BLOCKER 0, CRITICAL 2(R1·R2 — 폴링/재시도 생명주기 좁은 결함, 수정량 소)로 CHANGES_REQUESTED.
R1·R2 수정 + 대응 테스트 실제 플로우 정합판 교체 후 3차 재검증에서 나머지 전부 충족 → APPROVED 예상.

## 3차 리뷰 (Phase 6 2차 수정 검증 — 2026-11-16)

상태: **APPROVED** (BLOCKER 0 · CRITICAL 0 · WARNING 2 + 문서화 과제 유지)

### R1 해소 확인 (CR-005)
- app/jobs/cash_receipt/sync_job.rb:33-36 — 3000 분기에서 mark_issued! 가드 실패 시
  receipt.cancel_pending?이면 reschedule_poll 수행. 취소 요청 직후 첫 폴링(원본 3000)에서
  중단되지 않고 7000 → cancelled 확정까지 폴링 지속. MAX_POLLS 상한 재예약 적용(무한 폴링 없음).
- 테스트 교체 확인: 알림 미실행·재예약 → 7000 폴링(poll_count=1) → cancelled + cancelled_at 검증.

### R2 해소 확인 (CR-006)
- app/jobs/cash_receipt/issue_job.rb:77-81 — 재시도 분기 state: :pending 복귀 후 retry_job.
  2회째 실행은 라인 13·16 우회 → mark_processing! 경유 실제 재발행, 재실패 시
  mark_failed! + Notifier.notify_failure 도달 — CR-006 전 구간 완성.
- 테스트: pending 복귀 재시도 예약(:113-122)·재발행 재실패 → failed+알림(:167-180,
  perform_enqueued_jobs로 retry_job 2회 실수행) 실제 플로우 정합.
- 부작용 전수 확인: pending 30초 창 수동 충돌 없음·동시 실행 가드 보존·CR-004 분기 변동 없음·
  자동 재시도 정확히 1회.

### WARNING (기록 — 승인 범위)
[W3-R] issue_job_test :134-165 스텁 state()가 첫 호출부터 3000 반환 → CR-004 기발행 분기로
  흡수 통과. R2 재발행 성공 경로를 직접 검증하지 못함(간접 커버 존재). 스텁을 호출 횟수 기반
  (1회째 실패·2회째 성공) 수정 권장 — **코드 결함 아님, Tester 전달**.
[W4-R] 폴링 상한(MAX_POLLS 누적 약 36분) 도달 후 processing/cancel_pending의 수동 복구 수단
  부재 — 로그 경보 + W4 모니터링 과제로 부분 완화. F7/A6 착수 시 "확인 재개" 액션 또는 상한
  연장 검토. → 문서화.

### 기존 적합 항목 재확인
3차 변경분(sync_job 3000-elsif·issue_job pending 복귀·ko.yml retry 문구·테스트 교체)에 국한,
B1·B2·C2~C6·CR-001/003/004·TEN-001~004·SIMULATED 인프라 변동 없음. 문서화 과제(W3·W4·W5·W7·
W-N1·W-N2)는 03_implementation §9·§10에 등록 확인.

### 판정
**APPROVED.** W3-R(테스트 스텁 수정)·W4-R(복구 액션)은 차기 태스크 병행 반영 권장.
바로빌 실호출 스파이크 전 어댑터 파라미터 정합화(03_implementation §3)는 후속 게이트로 유지.
