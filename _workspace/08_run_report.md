# 08_run_report.md — 실행 검증 (Phase 8, F5)

- 실행일: 2026-11-16
- 방법: `bin/rails server -p 3211` 직접 구동 (로컬 제약: bin/dev 즉시 종료·curl 없음 → ruby net/http)

## 부트 로그

- `=> Booting Puma` / `Puma version: 8.1.1` (보안 업데이트 반영 버전) / `* Listening on http://127.0.0.1:3211` — 정상
- ERROR/Exception 키워드 0건

## HTTP 응답 (ruby Net::HTTP)

| 경로 | 응답 | 판정 |
|---|---|---|
| `/` (랜딩) | 200 | ✅ |
| `/session/new` (로그인) | 200 | ✅ |
| `/dashboard` (비인증) | 302 | ✅ 인증 리다이렉트 정상 |
| **`/cash_receipts` (F5 신규, 비인증)** | **302** | ✅ 인증 필수 라우트 정상 — 라우트·컨트롤러 부트 반영 확인 |

## WARN 분류

- [허용] 없음 — 부트 오류·렌더 오류 0건 → Phase 4 회귀 불필요

## F5 스파이크 (바로빌 실발행 1건) — 보류

- 테스트 인증키는 credentials 등록 완료, 어댑터는 `BAROBILL_LIVE=1` 게이트로 준비됨
- **보류 사유**: RegistCorp에 필요한 원비콕 사업자 정보(사업자번호·상호·대표자·주소·사업장 전화·
  이메일·업태·업종) 미제공
- 실행 방법(정보 수령 후): rails runner 1회 — `Barobill::MemberService.regist_corp` →
  `CashReceiptService.regist_and_issue` → `GetCashBillState` 3000 확인. 어댑터 파라미터
  정합화(03_implementation §3 표기: 메서드별 파라미터 순서·CashBillEx 태그명·GetCashBillInfo
  응답 필드)가 이 스파이크에서 검증됨 — 후속 게이트 유지
