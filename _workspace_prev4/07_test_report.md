# 07_test_report.md — F4+F9 병렬 배치 테스트 게이트 (Phase 7-S)

- 실행일: 2026-11-18 · 프로필: wonbikok-tester
- 범위: 리뷰(05_review.md 1·2차) "Tester 제안" 시나리오 보강 + 전체 게이트
- 소스 수정: **0건** (테스트 코드만 추가 — 기존 2파일에 보강 6건)

## 1. 게이트 결과 (전 구간 통과)

| 게이트 | 결과 |
|---|---|
| `bin/rails test` (전체) | **312 runs · 1389 assertions · 0 failures · 0 errors · 0 skips** |
| `bin/rubocop` | **126 files inspected, no offenses** |
| `bin/brakeman` | **Errors 0 · Security Warnings 0** |

- 기준선 대비: 306 runs·1315 assertions(2차 리뷰) → **+6 runs · +74 assertions** (전부 본 보강분, 기존 테스트 회귀 0)
- 실패 0건 — 원인 분류(버그 vs 테스트 오류) 해당 없음
- 외부 실호출 0: Triggerable은 singleton 스파이(`define_singleton_method` + `ensure` 원본 복원)로 대체,
  잔존 영수증 모사는 `CashReceipt.create!` 직접 생성(큐·바로빌 미진입), 솔라피 경로 미호출

## 2. 보강 시나리오 내역 (신규 6건)

### test/controllers/payments_controller_test.rb (+3)

| 테스트 | Rule ID | 내용 |
|---|---|---|
| 완납 건 오체크 취소 — UNPAID 복원·미확인 리스트 복귀·영수증 잔존 | PAY-002·CR-002·CR-005 | 전액 확인(PAID·auto 1회) → 완납 건은 미확인 리스트 부재·이력 섹션 취소 진입(C1) → issued 영수증 잔존 상태에서 취소 폼 안내 문구("발행 이력 화면에서 별도 취소") 단정 → 취소 POST로 UNPAID 복원(due_on 미경과)·`CashReceipt.count` 불변·영수증 issued 유지 → 미확인 리스트 복귀(등록 진입 재노출·취소 이력 행 비노출)·트리거 호출수 1 유지 |
| 기한 경과 완납 건의 오체크 취소 — OVERDUE 복원·리스트 복귀 | PAY-002 | due_on 3일 경과 PAID → 취소 → `OVERDUE?` 재계산 복원 + 미확인 리스트(등록 진입) 복귀 |
| 부분납 후 추가 수납 완납 전이 시 트리거 1회 | CR-002 | 100,000 POST → PARTIALLY_PAID·calls 비어 있음(보류) → 150,000 POST → PAID·`origin: :auto` 정확 1회(청구·시점 단정) |

### test/services/payments/confirm_service_test.rb (+3)

| 테스트 | Rule ID | 내용 |
|---|---|---|
| 완납 이후 재수납 차단·수동 재발급·취소 조합에서 auto 1회 유지 | PAY-001·CR-002 | 완납(auto 1회) → 재수납 거절(추가 호출 없음) → 수동 재발급 시도는 `origin: :manual`로 구분 기록 → 취소는 트리거 미호출 → 최종 `calls.count(origin: :auto) == 1` |
| 오체크 취소 후 재완납 — 새 PAID 전이로 트리거 재호출 1회 | CR-002·PAY-002 | 1회성은 청구 생애가 아닌 **PAID 전이 단위**임을 고정. 취소 후 재완납 시 `[ :auto, :auto ]` 2회(전이당 1회) — 실제 중복 발행은 Triggerable 내부 CR-001 멱등(mgt_key·duplicate)이 차단하는 구조를 문서화 |
| 부분납 청구 추가 수납으로 완납 전이 시 그 시점 1회 | CR-002 | 부분납 보류(빈 calls) → 완납 전이 시점 `origin: :auto` 1회·대상 청구 ID 단정 |

## 3. 리뷰 "Tester 제안" 3건 처리 결과

| 제안 | 처리 |
|---|---|
| PAY-002 완납 건 오체크 취소 E2E (PAID→UNPAID/OVERDUE 복원·미확인 리스트 복귀·영수증 잔존 안내) | ✅ 보강 2건 + 안내 문구·영수증 잔존 단정 추가 (§2 컨트롤러 1·2번) |
| LNK-003 CANCELLED issue_link/reissue 직접 POST 거부 유지 단정 | ⏭ **생략 — 기존 커버 확인** (중복 방지): `test/integration/invoices_flow_smoke_test.rb` "취소된 청구의 링크 발급 직접 POST는 거부되고 토큰이 발급되지 않는다"(issue+reissue POST·flash alert·`public_token` nil) + `test/services/billing_links/token_service_test.rb` blocked·부활 방지 2건 + `billing_links_controller_test.rb` 폐기·재발급 404 3건 |
| CR-002 완납 트리거 1회성(재수납·재발급·취소 조합) — 스파이 유지 | ✅ 보강 2건 (§2 서비스 1·2번) — 스파이 방식 유지 |
| (태스크 추가) 부분납 → 추가 수납 완납 전이 시 그때 트리거 1회 | ✅ 보강 2건 — 서비스(도메인 고정) + 컨트롤러(플로우) 이중 |

## 4. Rule ID 커버 매핑 (PAY / CR / LNK — 본 배치 갱신분)

### PAY

| Rule ID | 정상 | 경계 | 예외 |
|---|---|---|---|
| PAY-001 | active 수납 생성·합계 산식 | 취소 이력 합계 제외→재등록 가능 | 완납 재수납: 모델 거절 / 서비스 거절+트리거 무호출 / 컨트롤러 422 / 조합 테스트(신규) |
| PAY-002 | 취소 전이(사유·처리자 마스킹·시각)·UNPAID 복원 | OVERDUE 복원(due_on 기준)·복수 수납 1건 취소→PARTIALLY_PAID·재취소·사유 누락 | **완납 E2E(신규): 리스트 복귀·이력 행 비노출·영수증 잔존·안내 문구**·타 테넌트 취소 폼 404 |
| PAY-003 | 금액·원생명 힌트 | 부분납 포함·정렬 | PAID/CANCELLED/DRAFT 제외·타 테넌트 제외 |
| PAY-004 | duplicate 응답 무해 | — | 트리거 예외가 수납·PAID 전이를 롤백하지 않음 |

### CR

| Rule ID | 정상 | 경계 | 예외 |
|---|---|---|---|
| CR-001 | mgt_key 발급·IssueJob enqueue | 유니크 레이스 duplicate 통일 | 동일 청구 재트리거 skip — (신규 테스트가 "재완납 후 중복 발행은 Triggerable 내부 CR-001이 차단" 구조 문서화) |
| CR-002 | 전액 확인 origin:auto 1회(서비스+컨트롤러) | **부분납 보류→완납 전이 시점 1회(신규 2건)** / **취소 후 재완납 전이 단위 1회(신규)** / **재수납·수동 재발급·취소 조합에서 auto 1회 유지(신규)** | auto 게이트 C3(UNPAID blocked)·취소 청구 blocked·취소는 트리거 없음(E2E 단정)·DRAFT manual 허용 |
| CR-005 | (수동 취소 경로는 기존 cash_receipts 테스트 커버) | — | **오체크 취소가 영수증을 자동 취소하지 않음 + 수동 취소 안내 유도(신규 E2E 단정)** |

### LNK (기존 커버 유지 — 신규 추가 없음)

| Rule ID | 커버 | 위치 |
|---|---|---|
| LNK-001 | urlsafe 32자·개인정보 미포함·멱등 재사용·충돌 재시도 | token_service_test |
| LNK-002 | 13필드 화이트리스트·마스킹·타 청구/내부정보 미노출·no-store/noindex | billing_links_controller_test |
| LNK-003 | 재발급→이전 토큰 404·폐기·blocked | token_service_test·billing_links_controller_test·**invoices_flow_smoke_test(직접 POST 거부)** |
| LNK-005 | 폼 0·결제 버튼 부재 | billing_links_controller_test |

## 5. 남은 갭 (후속 권장)

1. **LNK-004 접근 로그** — PRD 14장 W3 확정상 유예(f9 보고서 §5-7). A4/A9 관리자 착수 시 연계 구현·테스트 필요.
2. **오체크 취소 → 현금영수증 수동 취소 전 경로** — 본 E2E는 "잔존 + 안내 문구"까지 단정. cash_receipts#cancel과 잇는 통합 시나리오는 F5 기존 커버와의 경계상 후속 여지.
3. **부분납 리마인더 금액 표기(총액 vs 잔액)** — 리뷰 잔여 WARNING 그대로(문구 정책 확정 후).
4. **PAY-001 동시성** — read-then-write 모델 + SQLite 단일 writer + 서비스 트랜잭션 + DB CHECK(amount>0) 이중 방어로 명시 수용(리뷰 W6). 프로세스 수평 확장 시 재검토.
5. 취소 이력 사유 조회 뷰 — 리뷰 잔여 WARNING(후속).

## 6. 결론

- 리뷰 1·2차 "Tester 제안" 시나리오 전부 해소(PAY-002 E2E·CR-002 1회성·부분납→완납 전이) — LNK-003은 기존 커버 확인으로 중복 생략.
- 전체 게이트 3종 통과, 기존 306건 회귀 0, 소스 수정 0건(테스트만 추가), 외부 실호출 0.
- **7-S 테스트 게이트: PASS** — F4+F9 병렬 배치는 APPROVED 상태 유지 가능.
