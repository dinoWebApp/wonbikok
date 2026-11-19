# 05_review.md — F10 추천 시스템 코드 리뷰 (Phase 5, 1차)

- 실행일: 2026-11-19 · 프로필: wonbikok-reviewer · 판정: **CHANGES_REQUESTED (BLOCKER 1 · CRITICAL 0 · WARNING 5)**
- 게이트 재검증: rubocop 198파일 0·brakeman 0·588 runs 2644 assertions 0 실패(Developer 보고 일치)

## BLOCKER

[B-1] Sales 로그인 폼 실제 동작 안 함(REF-005/F10 명세 위반·런타임 에러) —
  app/views/sales/sessions/new.html.erb:8 vs sales/sessions_controller.rb:17
- 뷰 `form_with url:`(scope 없음) → 필드가 `name="email"` 최상위로 제출되는데 컨트롤러는
  `params.expect(sales_session: [...])` → 브라우저 로그인 시마다 ParameterMissing(400). /sales 전체 UI 접근 불능.
  템플릿 렌더 실증 확인. 테스트 9건이 params를 직접 POST해 뷰 우회 → 588 green이 미검출.
- 수정: `form_with scope: :sales_session, url: sales_session_path` (1줄) + 뷰 폼 필드 name 검증
  통합 테스트 1건(렌더 HTML에 sales_session[email] 단정) 추가.

## WARNING

- W-1 트랜잭션 내부 외부 HTTP — phone_verification_service.rb:37-47 — deliver!가 transaction 블록 내부
  (SQLite 쓰기 잠금 홀드). create! 커밋 후 deliver! 호출로 의미 동일 유지 권장. 동기 Service 설계 예외 자체는 수용.
- W-2 뷰 DB 쿼리 — admin/sales_staffs/show.html.erb:169 `@sales_staff.referred_tenants.order(...)` —
  컨트롤러 prepare_commission_summary로 이관.
- W-3 N+1 — sales/dashboard_service.rb:27-35 tenant.subscription 행당 쿼리 — includes(:subscription).
- W-4 금전·이력 dependent: :destroy — sales_rep.rb:23-24 — commission_ledgers(REF-004 append-only)·
  referral_codes(이력 보존)가 rep 삭제 시 전량 삭제 — restrict_with_exception 권장.
- W-5 환불 ledger 역분 미구현 — v1.0 refund 기록-only 정합 무해·후속 문서화 확인(03_implementation §5·§7).

## 체크리스트 (12항목)

1 REF-001 PASS(로테이션 이력 보존·만료 거절 — W-4 유보) / 2 REF-002 PASS(claim! 원자 갱신·경쟁 테스트로 정확히 1회·
원가/할인액 기록·결제 롤백 시 claim 일관 롤백) / 3 REF-003/004 PASS(캡 경계일 포함·13개월 제외·rate 스냅샷 소급 없음 — W-5 문서화) /
4 REF-005/007 PASS(단일 경로 스코프·별도 세션 키·정지 3중 방어 — 접근은 B-1로 불능) / 5 REF-006 PASS(DB 원천 검증·
원자 소비·이중 레이트 리밋·code_digest bcrypt·로그 local 한정) / 6 인증 발송 조건부 PASS(동기 Service 타당 — 잡 인자
평문 방지·W-1 권장) / 7 PaymentService PASS(비추천 무변경·실패 rescue·트랜잭션 경계) / 8 관리자 CRUD PASS(W-2 유보) /
9 Sales:: 보안 PASS(잠금·reset_session·CSRF — B-1로 실사 불능) / 10 대시보드 집계 PASS(산식·연도 클램프 — W-3 유보·
strftime UTC는 기존 관행) / 11 아키텍처·회귀 PASS(verify_signup_phone! 헬퍼 검증 약화 아님 — 강제 경로 별도 검증) /
12 §5 요청 응답 완료.

## Tester 제안

- B-1 재발 방지: 렌더 HTML 폼 필드 name 검증 통합 테스트(최우선)
- REF-002: 결제 롤백 시 claim 원복 → 재시도 할인 재적용 시나리오
- REF-006: 검증 완료 직후 만료 경과 가입 거절 통합 경로
- REF-003: 캡 경계 초 단위 — 기존 서비스 테스트 양호

수정 범위: B-1 1줄(+테스트) — 수정 후 해당 파일·테스트 재검증으로 승인 가능.

## 2차 리뷰 (Phase 6 수정 후 — 2026-11-19)

상태: **APPROVED** (BLOCKER 0 / CRITICAL 0 / WARNING: W-5 후속 과제 문서화 유지)

### 1차 지적 해소

| ID | 해소 | 근거 |
|---|---|---|
| B-1 Sales 로그인 폼 scope 누락 | ✅ 실증 | sales/sessions/new.html.erb:8 `scope: :sales_session` — 템플릿 렌더 재실증 `name="sales_session[email]"`. 계약 테스트 test/controllers/sales/controllers_test.rb:22-29(렌더 필드명 단정+실제 POST 로그인)로 재발 방지 |
| W-1 트랜잭션 내 외부 HTTP | ✅ | phone_verification_service.rb:41-49 — deliver! create! 커밋 후 이동·Solapi rescue 유지(발송 실패≠발급 실패 규약 동일) |
| W-2 관리자 상세 뷰 쿼리 | ✅ | admin/sales_staffs_controller.rb:103 @referred_tenants 이관(422 재렌더 경로 포함) — 뷰 @변수만 |
| W-3 대시보드 N+1 | ✅ | sales/dashboard_service.rb:28 includes(:subscription) |
| W-4 dependent: :destroy | ✅ | sales_rep.rb:25-26 restrict_with_exception 2연관 — 앱 전역 destroy 경로 부재(grep)·sales_rep_test.rb:128-136 보존 테스트 |
| W-5 환불 차감 | 기록 | 문서화 유지(03_implementation §5-5·§7-2) — refund 실이체 전환 시 P1 과제 |

### 게이트 (Reviewer 직접 재실행)

- RuboCop 198 files 0 offenses / Brakeman 0 warnings / 테스트 590 runs, 2654 assertions, 0 failures(+2: B-1 계약·W-4 보존)

### 방어 회귀 확인

REF-001~007 강제 로직 전 항목 무변경·해당 테스트 전건 통과. 수정 범위는 표면 8파일에 국한 —
PaymentService·가입 플로우·마이그레이션·ko.yml 회귀 없음.

### Tester 권고(잔여)

REF-002 "결제 실패 롤백 후 할인 재적용" 경계 시나리오 정도 — B-1 방지 테스트는 이미 추가 완료.
