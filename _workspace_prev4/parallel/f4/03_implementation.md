# 03_implementation.md — task-f4 (입금 확인, W3 F4)

- 작성일: 2026-11-18
- 태스크: 병렬 배치 f4 — Payment 도메인(미확인 리스트·새 입금 등록+매칭 힌트·체크 처리·오체크 취소)
- Rule ID: PAY-001~004, CR-002, INV-003/005, TEN-001/003

## 1. 생성 파일 (화이트리스트 준수 — 기존 파일 수정 0건)

| 파일 | 내용 |
|---|---|
| `app/models/payment.rb` | Payment 모델 — enum status(active/cancelled), 검증(PAY-001·INV-003·미래일·수단·취소사유·재취소금지·테넌트 일치), `for_tenant` 스코프, `paid_total_for`, 처리자 마스킹 setter |
| `app/services/payments/confirm_service.rb` | 입금 확인 — 수납 등록 → PAID/PARTIALLY_PAID 전이, 완납 시 Triggerable origin: :auto 1회, 오체크 취소 + invoice 상태 재계산 |
| `app/services/payments/matching_hint_service.rb` | 매칭 힌트 — 금액(총액 정확 일치)·원생명 후보 반환 전용(자동 선택 없음) |
| `app/controllers/payments_controller.rb` | index(미확인 리스트)·new(등록+힌트)·create·cancel(폼)·cancel_payment — TEN-001 스코프, Turbo 규약(422/303), params.expect |
| `app/views/payments/index.html.erb` | 미확인 리스트 카드(원생명·청구액·수납합계·잔액·기한·상태 배지) + "입금 확인" 진입 |
| `app/views/payments/new.html.erb` | 힌트 검색·후보 패널(선택=폼 채움용 GET 링크) + 등록 폼 |
| `app/views/payments/cancel.html.erb` | 오체크 취소 사유 폼(필수·turbo_confirm) |
| `test/models/payment_test.rb` | 모델 11건 |
| `test/services/payments/confirm_service_test.rb` | 서비스 10건 (Triggerable 스파이) |
| `test/services/payments/matching_hint_service_test.rb` | 힌트 9건 |
| `test/controllers/payments_controller_test.rb` | 컨트롤러 9건 (Triggerable 스파이) |

## 2. 주요 설계 결정

1. **association 미의존 설계**: `invoice.payments`(invoice.rb 수정 필요) 대신 `Payment.where(invoice_id:)`·`Payment.paid_total_for(invoice)` 사용 — 3-S가 `has_many :payments` 추가 전에도 동작(병렬 독립성).
2. **CR-002 트리거 1회 보장**: PAID 재전이가 없도록 PAY-001(합계 ≥ 총액이면 신규 active 차단 → 완납 후 추가 수납 불가) + Triggerable 내부 CR-001 멱등(duplicate skip) 이중 방어. 부분납(PARTIALLY_PAID)에서는 트리거 미호출(PRD 14장 확정 — 원장 수동 발행은 기존 cash_receipts#issue 경로).
3. **PAY-004**: 트리거 계열 StandardError를 swallow(로그 warn) — 발행 실패가 수납 저장·PAID 전이를 롤백하지 않음. Triggerable 정상 응답(created/duplicate/blocked/needs_info)은 로그 기록만.
4. **오체크 취소와 영수증**: Payment 취소는 연관 CashReceipt를 자동 취소하지 않음 — CR-005 취소는 기존 `cash_receipts#cancel`(사유 폼) 경로로 원장 수동 처리. 취소 화면 notice로 안내 문구 유도(ko.yml). 자동 연쇄 여부는 리뷰/3-S 판단 사항.
5. **취소 후 상태 재계산**: active 합계 0 → due_on 경과 여부로 OVERDUE/UNPAID 복원, 잔여 합계 > 0 → PARTIALLY_PAID, 총액 이상 → PAID 유지. 취소 청구는 건드리지 않음(INV-003).
6. **처리자 마스킹(TEN-003)**: `confirmed_by=`/`cancelled_by=`에 CashReceipt#issued_by= 동일 정규식 마스킹. concerns 추출은 화이트리스트 밖이라 payment.rb 내부 구현(패턴 중복 허용 — 동일 규약의 2번째 인스턴스).
7. **초과 수납 허용**: PAY-001은 "이미 완납된 청구의 재등록"만 차단(PRD 원문). 합계가 총액을 넘는 신규 등록(실제 입금액 기록)은 허용하며 PAID 전이 — index 리스트에서 자동 제외되어 잔액 음수 노출 없음.
8. **index 대상 상태**: READY/SENT/UNPAID/OVERDUE/PARTIALLY_PAID(확정 청구). DRAFT 제외(금액 변동 가능), CANCELLED 제외(INV-003).
9. **힌트 매칭 기준**: 청구 총액(total_amount) 정확 일치 + 원생명 포함. 부분납 건의 "잔액 일치" 매칭은 명세 범위 밖(태스크 명세: total_amount 일치).
10. **뷰**: 웜 오렌지 토큰(text-brand-700)·shared 파셜(page_header/card/badge/empty_state/form_field/button) 재사용, 터치 44px(min-h-11·btn-lg), PARTIALLY_PAID=warning·PAID=success 배지(16.2). 등록 제출은 확인 단계 없음(F4 수용조건 "체크→발행 2탭 이내"), 취소만 turbo_confirm(PRD 15.4 되돌릴 수 없는 작업).
11. **연습 모드**: ConfirmService는 practice 분기 없음 — 발행의 SIMULATED 처리는 F5 계층(Triggerable→IssueJob→Barobill 어댑터 cert_key 분기)이 담당(단일 책임).

## 3. ko.yml 필요 키 목록 (3-S에서 추가 — 병렬 태스크는 미추가)

```yaml
  payments:
    won: 원
    status:
      active: "정상 수납"
    index:
      title: 입금 확인
      subtitle: "입금된 원생을 확인하고 현금영수증 발행까지 처리합니다."
      month_filter: "청구월 이동"
      filter: 조회
      due: "기한 %{date}"
      empty: "미확인 입금이 없습니다."
      empty_description: "이번 달 청구 전원의 입금이 확인되었습니다."
      empty_cta: "청구 화면으로 이동"
      confirm_button: 입금 확인
      label_total: 청구액
      label_paid: 수납합계
      label_remaining: 잔액
    new:
      title: 새 입금 등록
      subtitle: "입금액·입금일·수단을 확인하고 체크 처리합니다."
      hint_title: 입금 매칭 힌트
      hint_amount: 입금액
      hint_name: 원생명
      hint_search: 후보 찾기
      hint_matched_amount: "금액 일치"
      hint_select: 선택
      hint_notice: "추천은 참고용입니다. 최종 판단은 원장님 몫입니다."
      hint_empty: "일치하는 후보가 없습니다. 직접 선택해 주세요."
      invoice_label: 대상 청구
      invoice_blank: "청구를 선택해 주세요"
      amount_label: 입금액
      paid_on_label: 입금일
      method_label: 수단
      method_blank: "수단을 선택해 주세요"
      memo_label: 메모
      auto_issue_notice: "전액 확인 시 현금영수증이 자동 발행됩니다(설정에 따라)."
      submit: "입금 완료로 표시"
    cancel:
      title: "입금 확인 취소"
      reason: 취소 사유
      notice: "취소해도 수납 이력은 삭제되지 않습니다. 이미 발행된 현금영수증은 발행 이력 화면에서 별도 취소해 주세요."
      confirm: "이 입금 확인을 취소할까요? 청구 상태가 재계산됩니다."
      submit: "입금 확인 취소"
    method:
      transfer: 계좌이체
      card: 카드
      cash: 현금
      other: 기타
    notices:
      confirmed: "%{name} 입금을 확인했습니다."
      cancelled: "입금 확인을 취소했습니다."
    errors:
      cancel_reason_blank: "취소 사유를 입력해 주세요."
  # 기존 섹션 보강
  invoices:
    status:
      PAID: 완납            # 추가 필요 (기존 6종에 없음)
      PARTIALLY_PAID: 부분납 # 추가 필요
  enums:
    invoice:
      status:
        PAID: 완납            # 추가 필요 (선택 — 일관성)
        PARTIALLY_PAID: 부분납 # 추가 필요
  activerecord:
    errors:
      models:
        payment:
          attributes:
            base:
              already_fully_paid: "이미 완납 처리된 청구입니다. 중복 등록할 수 없습니다."
            invoice:
              cancelled_invoice: "취소된 청구에는 수납을 등록할 수 없습니다."
            paid_on:
              future_date: "입금일은 미래일 수 없습니다."
            tenant:
              tenant_mismatch: "청구와 교습소가 일치하지 않습니다."
            status:
              already_cancelled: "이미 취소된 수납입니다."
```

뷰·컨트롤러가 참조하는 기존 키: `common.required`·`common.back`·`errors.form`·`invoices.status.*`(PAID·PARTIALLY_PAID 제외 기존 6종).

주의: **컨트롤러 뷰 테스트는 payments.* 키가 ko.yml에 없어도 실패하지 않게 DB 파생 텍스트(원생명·금액)만 단정**함 — 3-S 병합 후에도 추가 수정 불요.

## 4. 3-S 전달 메모

### 4.1 마이그레이션 (권장 스펙)

```ruby
create_table :payments do |t|
  t.references :invoice, null: false, foreign_key: true
  t.references :tenant,  null: false, foreign_key: true
  t.integer  :amount,    null: false            # 원 단위
  t.date     :paid_on,   null: false
  t.string   :method,    null: false            # transfer/card/cash/other
  t.string   :memo
  t.string   :status,    null: false, default: "active" # active/cancelled
  t.string   :cancel_reason
  t.datetime :cancelled_at
  t.string   :cancelled_by                     # 마스킹 저장(모델 setter)
  t.string   :confirmed_by                     # 마스킹 저장(모델 setter)
  t.datetime :confirmed_at
  t.timestamps
end
add_index :payments, [ :invoice_id, :status ] # active 합계 조회·PAY-001 지원
add_index :payments, :tenant_id
```

- 본 태스크가 가정한 컬럼명과 01_plan §3 표 일치(invoice_id·tenant_id·amount·paid_on·method·memo·status·cancel_reason·cancelled_at·cancelled_by·confirmed_by·confirmed_at). cancelled_by는 Task 프롬프트 명세에 없으나 01_plan 소유권 표에 있어 포함 — 3-S에서 확정 바람(미포함 시 `cancel`의 cancelled_by 저장을 제거해야 함).
- **PAY-001 동시성 방어**: 모델 검증은 read-then-write라 동시 insert 레이스의 완전 방어는 아님. SQLite 단일 writer + 서비스 트랜잭션으로 실질 방어되며, 추가로 `amount > 0` CHECK 제약(또는 상태별 부분 인덱스)을 3-S에서 검토 권장. 합계 상한 트리거는 SQLite 유지보수 비용 대비 효과 낮음 — 3-S 판단.

### 4.2 routes.rb (필요 라우트 — 3-S 결선)

```ruby
  # 입금 확인 (W3 F4)
  resources :payments, only: %i[index new create] do
    member do
      get :cancel           # 오체크 취소 사유 폼 (PAY-002)
      post :cancel_payment  # 취소 처리(사유 필수)
    end
  end
```

사용 경로 헬퍼: `payments_path`·`new_payment_path`·`cancel_payment_path(id)`·`cancel_payment_payment_path(id)`·`invoices_path(month:)`(빈 상태 CTA).

### 4.3 기타

- `invoice.rb`: 수정 불필요(f4 코드는 association 미의존). 3-S가 `has_many :payments` 추가해도 충돌 없음.
- `tenant.rb`: 수정 불필요(`Payment.for_tenant(current_tenant)` 사용).
- Payment 컬럼명 `method`는 `Object#method`를 덮음(모델에 주석 명시) — 인스턴스에서 `.method(:sym)` 리플렉션 금지. 3-S에서 `payment_method` 리네임 원하면 모델·서비스·뷰·테스트 일괄 수정 필요.
- W2 `remindable` 스코프는 PAID/PARTIALLY_PAID 제외 — 부분납도 리마인더 대상 유지 필요(PRD F4). 현재 remindable은 `status: [ :SENT, :UNPAID, :OVERDUE ]`만 포함 → **부분납 리마인더 누락** 가능. 3-S에서 `remindable`에 `:PARTIALLY_PAID` 추가 검토 바람(PRD F4 "잔액은 미납으로 유지되며 리마인더 대상 유지").

## 5. 테스트 목록 (작성만 — 실행은 3-S 이후; payments 테이블 미존재로 미실행)

### test/models/payment_test.rb (11건)
| 테스트 | Rule |
|---|---|
| 정상 active 수납 생성 | - |
| 완납 합계 도달 후 추가 active 수납 거절 | PAY-001 |
| 취소 이력은 합계 제외 → 재등록 가능 | PAY-001·002 |
| 금액 0·음수 거절 | - |
| 입금일 미래 거절 | - |
| 수단 허용 목록 제한 | - |
| 취소 전이 사유 필수 | PAY-002 |
| 취소 상태 복원(재취소) 거절 | PAY-002 |
| 취소 청구 수납 등록 거절 | INV-003 |
| tenant-invoice 불일치 거절 · for_tenant 격리 | TEN-001 |
| 처리자 마스킹 저장(confirmed_by·cancelled_by·비전화 보존) | TEN-003 |
| paid_total_for active만 합산 | PAY-002 |

### test/services/payments/confirm_service_test.rb (10건)
| 테스트 | Rule |
|---|---|
| 전액 확인 → PAID 전이 + origin: :auto 1회·마스킹 | CR-002 |
| 부분납 → PARTIALLY_PAID + 트리거 미호출 | CR-002(부분 보류)·INV-005 |
| 완납 청구 재수납 거절 + 트리거 재호출 없음 | PAY-001 |
| 트리거 예외가 수납·PAID 전이를 롤백하지 않음 | PAY-004 |
| duplicate 응답 무해(수납 성공 유지) | CR-001·PAY-004 |
| 취소 청구 수납 거절 | INV-003 |
| 취소 이력(사유·마스킹 처리자·시각) + UNPAID 복원 | PAY-002 |
| 기한 경과 청구 전액 취소 → OVERDUE 복원 | PAY-002 |
| 복수 수납 1건 취소 → PARTIALLY_PAID 유지 | PAY-002·INV-005 |
| 재취소 거절 · 사유 누락 거절 | PAY-002 |

### test/services/payments/matching_hint_service_test.rb (9건)
| 테스트 | Rule |
|---|---|
| 금액 정확 일치 후보 · 불일치 후보 없음 | PAY-003 |
| PAID·CANCELLED·DRAFT 제외 | PAY-001·INV-003 |
| 원생명 유사 후보 | PAY-003 |
| 부분납(미완납) 포함 | PAY-003 |
| 금액 후보 우선 정렬 | PAY-003 |
| 타 테넌트 제외 | TEN-001 |
| 선택 상태 개념 없음(반환은 후보 목록만) | PAY-003 |
| 잘못된 월 형식 당월 보정 | - |

### test/controllers/payments_controller_test.rb (9건)
| 테스트 | Rule |
|---|---|
| 비로그인 → 로그인 리다이렉트 | - |
| 리스트 잔액 표시 + 타 테넌트 미노출 | TEN-001 |
| 힌트 후보 표시 | PAY-003 |
| 타 테넌트 수납 취소 폼 404 | TEN-001 |
| 전액 등록 → 303 + PAID + auto 1회 | CR-002 |
| 부분납 등록 → PARTIALLY_PAID + 미호출 | CR-002 |
| 완납 재등록 422 | PAY-001 |
| 타 테넌트 청구 등록 거절 | TEN-001 |
| 취소 422(사유 누락)/303(사유)+UNPAID 복원 · 취소 폼 렌더 | PAY-002 |

스텁 원칙: Triggerable은 `define_singleton_method` 스파이(호출 기록·outcome 주입) — 외부(바로빌·솔라피) 실호출 0.

## 6. 자체 검증 결과

- `bin/rubocop` (app 4 + test 4 = 8파일): **0 offenses**
- ERB 3종: Rails `ActionView::Template::Handlers::ERB` 컴파일 + Ruby AST 파싱 **OK** (new.html.erb의 `map do..end, args` 문법 오류 1건 발견·수정 완료)
- `bin/rails runner` 클래스 오토로드·`Payment.active` enum 스코프·`UnpaidRow.remaining_amount`·Triggerable Result 멤버 검증 **OK**
- 미실행(규약 준수): `bin/rails test`(전체·파일 단위 모두 — payments 테이블 미존재)·서버 기동
