# 01_plan.md — W3 잔여 병렬 배치: F4 입금 확인 + F9 학부모 청구 링크

- 작성일: 2026-11-18
- 파이프라인: **병렬 배치 (HARNESS_CONVENTION §6.14)** — `0 → 1-P → ✋승인(배치 1회) → 2(직렬) → 3-P(병렬 구현 ×2) → 3-S(통합) → 4 → 5 → 6? → 7-P(선택) → 7-S → 8 → 9`
- 호출 프로필(일반 모드): wonbikok-developer / wonbikok-reviewer / wonbikok-tester
- 선행 완료: F5(바로빌) — Triggerable `trigger_issue_for(invoice, issued_by:, origin:)` 게이트·Invoice enum PAID/PARTIALLY_PAID 선활성화 상태

## 1. 태스크 분해 (AGENTS 병렬 후보 조합 채택)

| task-id | 범위 | PRD | Rule ID |
|---|---|---|---|
| **f4** | 입금 확인 — Payment 도메인: 미확인 원생 리스트, 새 입금 등록+매칭 힌트(금액·이름 후보 추천), 체크 처리(전액/부분), 오체크 취소(이력), **F5 Triggerable 연결(origin: :auto)** | 7장 F4(308행) | PAY-001~004, CR-002, INV-003(취소청구 제외), TEN-001/004 |
| **f9** | 학부모 청구 링크 — 공개 토큰 페이지 `/b/{token}`: 교습소명·문의처(원터치 발신), 금액 큰 글씨·내역, 납부 기한·상태, 계좌 복사 원탭(clipboard 토스트), 현금영수증 자동발급 안내, 링크 취소·재발급, 만료 안내 페이지 | 8장(425행) | LNK-001~005, TEN-001/003, INV(스냅샷 표시) |
| **integ**(3-S) | 통합 — 마이그레이션 단 1회(payments 테이블 + invoices.public_token/토큰 상태), routes 결선, ko.yml 병합, invoice.rb 수정(토큰·납부상태 헬퍼), invoices 뷰 수정(F4 진입 + F9 링크 버튼), 전체 게이트 | — | 전체 정합 |

## 2. 병렬 안전 판정 (3조건)

| 조건 | f4 ∥ f9 | 판정 |
|---|---|---|
| 파일 소유권 분리 | 아래 표 — 겹치지 않음(둘 다 신규 파일 중심) | ✅ |
| 의존 없음 | f4는 F5 Triggerable(기존)만 호출, f9는 invoice 상태를 읽기만(읽기 의존은 무해) | ✅ |
| 공유 파일 비수정 | routes.rb·마이그레이션 체인·ko.yml·invoice.rb·invoices 뷰·PRD/AGENTS — **병렬 태스크 수정 금지, 전부 3-S 통합에서 처리** | ✅ (규약 준수 설계) |

## 3. 파일 소유권 표 (병렬 fan-out)

### task-f4 (생성 전용)
- `app/models/payment.rb` (컬럼 가정: invoice_id·tenant_id·amount·paid_on·method·memo·status(active/cancelled)·cancel_reason·cancelled_at·cancelled_by·confirmed_by·confirmed_at — 마이그레이션은 3-S)
- `app/services/payments/confirm_service.rb` (체크 처리·부분납·완납 전이 invoice.update!·**Triggerable origin: :auto 호출**·PAY-001 재완납 차단)
- `app/services/payments/matching_hint_service.rb` (PAY-003: 금액·원생명 후보 추천, 자동 선택 아님)
- `app/controllers/payments_controller.rb` (미확인 리스트·새 입금 등록 폼·create·cancel)
- `app/views/payments/*.erb` (미확인 리스트·등록 폼·취소 폼)
- `test/models/payment_test.rb`·`test/services/payments_*_test.rb`·`test/controllers/payments_controller_test.rb`
- 산출물 `_workspace/parallel/f4/03_implementation.md`

### task-f9 (생성 전용)
- `app/controllers/billing_links_controller.rb` (공개·비로그인: show_by_token — TEN-001 노출 최소·LNK-002)
- `app/services/billing_links/token_service.rb` (LNK-001 예측 불가 토큰 생성·재발급·취소 — invoices.public_token 가정)
- `app/javascript/controllers/clipboard_controller.js` (계좌 복사 원탭·토스트 — Stimulus)
- `app/views/billing_links/show.html.erb`·`expired.html.erb` (금액>계좌>안내 위계·웜 오렌지 토큰·LNK-003 만료 안내)
- `test/controllers/billing_links_controller_test.rb`·`test/services/billing_links_token_service_test.rb`
- 산출물 `_workspace/parallel/f9/03_implementation.md`

### integ (3-S 통합 — 단일 Developer)
- 마이그레이션 1개: `payments` 테이블 + `invoices.public_token(string·유니크)·public_token_revoked_at·public_token_issued_at`
- `config/routes.rb`: payments 리소스 + `/b/:token` 공개 라우트 + 원장 쪽 링크 발급/취소 액션
- `config/locales/ko.yml` 병합, `app/models/invoice.rb`(토큰 헬퍼·납부 상태 표시용), `app/views/invoices/index.html.erb`(F4 입금확인 진입 + F9 링크 버튼 열)
- MessageLog 발송 링크에 청구 URL 포함(F3 안내 알림톡에 /b/{token} 주입 — 솔라피 SIMULATED 유지)

## 4. fan-out 위임 공통 제약 (각 Developer 프롬프트에 포함)

- 소유권 화이트리스트: 위 표의 자기 파일만 생성/수정 — **routes.rb·마이그레이션·ko.yml·invoice.rb·기존 뷰·PRD/AGENTS 수정 금지**
- 자체 검증: `bin/rubocop`/`bin/brakeman` 자기 파일 인자로만, `bin/rails test` 전체 실행 금지(형제 태스크 코드로 오탐)
- repo-wide 금지: 마이그레이션 생성·전체 테스트·서버 기동은 3-S 이후만
- 컬럼/모델 의존은 "3-S에서 확정할 시그니처 가정" 하에 작성(f4: Payment 컬럼명 위 표, f9: invoice.public_token 가정) — 통합 시 불일치 발견되면 3-S에서 조정

## 5. Phase 2 문서 현행화 (직렬 1회, 승인 후)

- PRD.md: 14장 W3 F4/F9 구현 확정 사항 블록(Payment 스키마·토큰 설계·매칭 힌트 정책), 9.1 납부 상태 전이 완결(PAID/PARTIALLY_PAID 전이 주체=ConfirmService), 오픈 이슈(W-N1/W-N2 정책 확정 반영)
- AGENTS.md: 진행 표는 Phase 9에서 갱신(Phase 2에서는 규칙 표 필요시만)
- `_workspace/02_prd_update.md` 기록

## 6. 실행 계획 (승인 후 자동)

| Phase | 내용 | 프로필 |
|---|---|---|
| 2 | PRD 현행화(직렬) | 오케스트레이터 |
| 3-P | f4·f9 동시 구현(상한 2 ≤ 3) | wonbikok-developer ×2 |
| 3-S | 통합(마이그레이션 1회·routes·ko.yml·invoice.rb·뷰 결선) + db:migrate + 전체 게이트 선행 | wonbikok-developer ×1 |
| 4 | rubocop·brakeman·rails test 전체 | 오케스트레이터 |
| 5 | 리뷰(PAY·LNK·CR-002 연결·공개 페이지 노출 집중) | wonbikok-reviewer |
| 6? | 지적 시 최소 수정 | wonbikok-developer |
| 7-S | 전체 테스트 게이트(+필요 시 시나리오 보강은 Reviewer 지적 기반) | wonbikok-tester |
| 8 | 부트 검증(/b/{token} 비로그인 200·payments 302 포함) | 오케스트레이터 |
| 9 | 완료 보고·AGENTS 진행 표·progress 리셋 | 오케스트레이터 |

## 7. 리스크

1. **컬럼 가정 불일치**(f4/f9가 가정한 시그니처 ↔ 3-S 마이그레이션) — 3-S에서 대조·조정, 게이트로 방어
2. **공개 페이지 노출**(LNK-002) — Reviewer 집중 검증 항목으로 지정(타 청구·내부정보 미노출)
3. **PAY-001 완납 재처리 차단** — ConfirmService 가드 + DB 제약(3-S) 이중 방어
4. **invoice.rb 통합 충돌** — 병렬 태스크가 수정 안 하므로 구조적 예방, 3-S 단일 수정
5. F4 UI가 invoices 뷰 진입 버튼을 필요로 하나 3-S에서 결선 — 병렬 태스크는 payments 뷰 내부만 완결
