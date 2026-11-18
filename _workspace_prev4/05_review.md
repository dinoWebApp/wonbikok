# 05_review.md — F4+F9 병렬 배치 코드 리뷰 (Phase 5, 1차)

- 실행일: 2026-11-18 · 프로필: wonbikok-reviewer · 판정: **CHANGES_REQUESTED (CRITICAL 2 · WARNING 6)**
- 게이트 재검증: rubocop 126파일 0·brakeman 0·300 runs 1274 assertions 0 실패(기존 236 회귀 없음).
  integ 수정 f4/f9 테스트 5건 전부 교정(약화 아님) 확인 — 스냅샷 비교·스텁 ensure 복원·TEN-001 단정 교정·INV-001 회피·임시 라우트 제거. Triggerable 스파이 유지.

## CRITICAL

[C1] **PAY-002/F4 수용조건 — 오체크 취소 UI 진입 경로 부재(죽은 기능)** — app/views/payments/index.html.erb
- `cancel_payment_path`(GET 취소 폼) 링크가 앱 전체 뷰에서 0곳(cancel.html.erb 내부 POST 폼 제외). 취소 폼·액션·서비스·테스트 완비되었으나 도달 불가.
- 구조 문제: `unpaid_rows`는 `paid_total < total`(미완납)만 표시 → **전액 확인(PAID) 청구는 리스트에서 사라져 완납 건의 오체크 취소(주 시나리오) 불가**. 부분납 카드에도 취소 진입 없음. F4 수용조건 "오체크 취소 시 결과 명확히 표시" 성립 불가.
- 수정: payments#index에 완납 포함 수납 이력 섹션(또는 청구별 수납 행) + 각 active 수납 행에 취소 폼 진입 버튼.

[C2] **LNK-003/INV-003 — CANCELLED 청구 링크 발급 서버 가드 부재** — app/controllers/invoices_controller.rb issue_link·app/services/billing_links/token_service.rb
- `Invoice#cancel!` → revoke_for 연계 설계와 달리 `issue_link`(reissue 포함)는 CANCELLED 검증 없이 재발급 가능. 뷰는 버튼 숨김뿐(link_manageable) — 직접 POST 무방비. 취소 청구 공개 페이지에 금액+계좌 복사가 다시 열려 오납 유도 여지(금전 혼선).
- 수정: issue_link에서 CANCELLED 거부(또는 TokenService.issue_for/reissue_for에 CANCELLED 가드).

## WARNING (기록)

[W3] 부분납 리마인더 총액 표기 — message_builder.rb:128 — `%{amount}`=total_amount, 잔액 혼동 여지. 오픈 이슈 등재 권장.
[W4] "청구링크" 카카오 변수 규격 — 토큰 보유 청구만 변수 존재 → 운영 템플릿 #{변수} 세트 불일치 시 솔라피 거부 위험. 템플릿 등록 시 통일 필요.
[W5] 운영 URL placeholder(example.com) — 배포 전 config 갱신 필수.
[W6] PAY-001 동시성 — read-then-write. SQLite 단일 writer 전제 명시적 수용(타당)·프로세스 확장 시 재검토.
[W7] 힌트 대상 불일치 — matching_hint는 READY 제외 vs payments#index는 READY 포함. 발송 전 입금 시 힌트 미등장.
[W8] DRAFT 수납 서비스 경로 허용 — confirm_service 직접 호출 시 DRAFT→PAID 가능(컨트롤러는 차단). DRAFT 가드 제안.

## 체크리스트 통과 (16항목 중 12)

PAY-001 모든 경로(on:create)·PAY-002 로직(사유 필수·재계산·재취소 차단)·PAY-003 추천 전용·PAY-004/CR-002(완납 시만 origin:auto 1회·부분납 보류·트리거 예외 swallow·enqueue 트랜잭션 일관)·LNK-001(urlsafe 32자·부분 유니크·개인정보 미포함)·LNK-002(BillingView 13필드 화이트리스트·@invoice 미전달·expired 무정보 404·no-store/noindex)·LNK-003 폐기/재발급/만료(C2 제외)·LNK-005 폼 0·TEN-001(전 액션 스코프·공개 토큰 단일)·TEN-003(마스킹·tel: PRD 허용·처리자 마스킹)·remindable 회귀(조건 유지·PAID 제외)·message_builder 가드(SIMULATED 무변경)·index 뷰 위계·ko.yml 전수·Turbo 422/303·routes.

integ 집중 요청 7건 판정: 1 수용·2 수용+추가 지적(=C1·C2)·3 수용·4 W4 후속·5 W5 기록·6 부분 수용(C2 지적)·7 수용.

## Tester 전달 제안 (Rule ID)

- PAY-002: 완납 건 오체크 취소 E2E(C1 수정 후) — PAID→UNPAID/OVERDUE 복원·현금영수증 잔존 안내
- LNK-003: CANCELLED issue_link 직접 POST 거부(C2 수정 후)·폐기→재발급→이전 토큰 404
- CR-002: 완납 트리거 1회성(재발급·취소·재수납 조합) — 스파이 유지

수정 후 재검증 범위: CRITICAL 2건 파일 + payments 뷰/invoices_controller 결선 회귀(전체 게이트 재실행).

## 2차 리뷰 (Phase 6 수정 후 재검증 — 2026-11-18)

상태: **APPROVED** (BLOCKER 0 · CRITICAL 0 · WARNING 기록)

수정 검증:
- C1(PAY-002 오체크 취소 UI 진입): payments/index.html.erb 수납 이력 섹션(완납 포함·행별 취소 진입)
  + 부분납 카드 수납 내역 접기. payment_history_rows current_tenant 스코프(TEN-001)·
  confirmed_by 마스킹 표시(TEN-003)·월 스코프 테스트 단정. 해소.
- C2(CANCELLED 링크 발급 가드): TokenService issue_for/reissue_for :blocked + invoices_controller
  선제 거부(303+alert). revoke_for 무가드는 cancel! 연계 유지에 필수·안전 방향(정확한 비대칭).
  직접 POST E2E 거부·토큰 부활 방지 테스트. 해소.
- W8: ConfirmService DRAFT 가드(:draft_invoice). W7: 매칭 힌트 READY 포함(index와 일치).
- f4 테스트 4파일 require "test_helper" 복구.

게이트(직접 재검증): rails test 306 runs·1315 assertions·0 failures / rubocop 126 files 0 offenses / brakeman 0 warnings.

잔여 WARNING(기록): 취소 이력 사유 조회 뷰 부재(후속)·부분납 리마인더 총액 표기(후속)·
카카오 "청구링크" 변수 규격 일관성(운영 템플릿 등록 시)·운영 URL placeholder(배포 전 config)·
PAY-001 동시성 모델 검증 의존(명시 수용).

Tester 제안(PAY-002): 완납 건 오체크 취소 E2E(PAID→UNPAID/OVERDUE 복원·취소 후 미확인 리스트 복귀)·
CANCELLED issue_link 직접 POST 거부 유지.
