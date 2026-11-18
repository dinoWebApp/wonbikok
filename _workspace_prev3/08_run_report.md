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

## F5 스파이크 결과 (2026-11-16 실시 — 테스트키·testws·BAROBILL_LIVE=1, 더미 사업자정보 2208100020)

### 실행 흐름과 확정 사항
1. `RegistCorp` 회원사 자동 가입 **성공** (wbspike01·사업자번호 2208100020). 초기 -32001 =
   더미 사업자번호 체크섬 실패 — 체크섬 유효 번호로 해소. (이미 가입 시 -32000 → 콘솔 연결 경로)
2. `RegistAndIssueCashBill` 발행 **성공** (value=1) — CashBillEx 태그는 WSDL 실측 확정분:
   Franchise* 접두어 5종 교정·**TradeDate 필수**(D-1·현재 시각)·Invoice 태그·SMSSendYN 필수.
   동일 MgtKey 재발행 시도 → **-11013 거절 = 바로빌 측 멱등 실측 확인(CR-001 상호 보강)**.
3. `GetCashBillState` **국세청 승인번호 TS3980617 수령**. 실측 응답 구조: GetCashBillStateResult가
   복합 노드(내부 BarobillState·NTSConfirmNum·NTSConfirmMessage 등) — 파싱 교정 후
   `barobill_state: 2000(발급완료)` 정확 반영 확인.
   ※ 테스트 서버 관측: 승인번호 부여 시점에 NTSConfirmDT 미표기·2000 유지(2500/3000 전이는
   테스트 서버 주기에 의존) — 운영 관찰 사항으로 기록. 어댑터는 3000만 ISSUED로 처리(CR-003).

### 어댑터 파라미터 정합화(스파이크 게이트) — 확정 완료
| 항목 | 문서 가정 → 실측 확정 |
|---|---|
| 엔드포인트 | CASHREIPT.SVC(404) → **CASHBILL.asmx** (공통 API도 동일 asmx에 포함) |
| RegistCorp | BizCategory→**BizClass**, Addr→**Addr1(+Addr2)**, **MemberName** 필수, 사업자번호 체크섬 검증(-32001) |
| 발행 | CashBillEx 태그 → **Invoice**, **SMSSendYN 필수**, CashBillEx 자식 = Franchise 접두어 5종 + TradeDate |
| 상태 | GetCashBillInfo(부재) → **GetCashBillState**(복합 응답: Result 내부 BarobillState·NTSConfirmNum) |
| 멱등 | 동일 MgtKey 재발행 → **-11013 거절 실측** |
| 오류코드 | -32001 사업자번호·-10001 파트너-회원사 미연결·-11703 FranchiseMemberID 불일치 실측 |

### 결론
F5 어댑터의 문서 기반 가정이 전부 실측으로 교정 완료 — **바로빌 연동 실측 검증 게이트 통과**.
남은 운영 전환 조건: 운영 인증키(release_auth_key 이미 등록)·원장 실사업자 정보 기반 RegistCorp·
알림톡 템플릿 실심사. 수동 발행 화면에서 실제 운영 건은 F4 트리거 연결 후 본격 사용.
