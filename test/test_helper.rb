ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# rate_limit은 클래스 로드 시점의 cache_store를 캡처하므로(test env :null_store),
# 컨트롤러 로드 전에 MemoryStore로 교체해야 통합 테스트에서 429를 검증할 수 있다.
RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new
ActionController::Base.cache_store = RATE_LIMIT_STORE

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    fixtures :all

    # Add more helper methods to be used by all tests here...

    # 사용자·보호자는 encrypts 컬럼을 포함하므로(raw SQL 삽입 시 암호화 우회됨)
    # fixtures가 아닌 모델 API로 생성한다(TEN-003).
    def create_owner_user(tenant: nil, name: "테스트 학원", phone_number: "01033334444", password: "password123", step: 6)
      tenant ||= Tenant.create!(name: name, onboarding_step: step)
      user = tenant.users.create!(phone_number: phone_number, password: password)
      [ tenant, user ]
    end

    def create_student_with_guardian(tenant:, name: "김민준", phone_number: "01011112222")
      tenant.students.create!(name: name, monthly_fee: 250_000, payment_day: 25,
                              status: :active,
                              guardians_attributes: { "0" => { name: "#{name} 어머님", phone_number: phone_number } })
    end

    # W2 테스트 공용: 최소 필수값으로 Invoice 생성(스냅샷 포함 — TEN-004)
    def create_invoice(tenant, student, **attrs)
      tenant.invoices.create!({
        student: student,
        target_month: Date.current.strftime("%Y-%m"),
        student_name_snapshot: student.name,
        base_amount: student.monthly_fee.to_i,
        due_on: Date.current
      }.merge(attrs))
    end

    # test 환경 캐시는 :null_store라 캐시 의존 기능(CSV 오류내역 만료, rate limit)을
    # 검증하려면 블록 안에서만 MemoryStore로 교체한다(리뷰어 메모 반영).
    def with_memory_cache
      original_store = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = original_store
    end

    # ── F10 가입 휴대폰 인증 지원 ──
    # 기존 가입 테스트 호환용: "이미 인증을 마친 사용자" 상태를 모델 API로 재현한다.
    # 검증 약화가 아니다 — 가입 create는 소비(consume!)를 서버에서 강제하며(REF-006),
    # 실제 인증 플로우(발송→코드 검증)는 서비스·E2E 테스트가 실제 서비스 경유로 검증한다.
    def verify_signup_phone!(phone_number, at: Time.current)
      SignupVerification.create!(
        phone_number: phone_number.to_s.gsub(/[^0-9]/, ""),
        code_digest: BCrypt::Password.create("000000"),
        expires_at: SignupVerification::TTL.from_now,
        verified_at: at
      )
    end

    # E2E용: 실제 서비스 플로우(발송→검증)를 거치되 코드가 결정적이도록 generate_code를 고정.
    # bcrypt 해시 저장·만료·시도 제한 등 나머지 경로는 모두 실제 코드 경유.
    def with_fixed_verification_code(code = "123456")
      original = Signup::PhoneVerificationService.method(:generate_code)
      Signup::PhoneVerificationService.define_singleton_method(:generate_code) { code }
      yield code
    ensure
      Signup::PhoneVerificationService.define_singleton_method(:generate_code, original)
    end
  end
end

module ActionDispatch
  class IntegrationTest
    setup do
      RATE_LIMIT_STORE.clear
    end

    def log_in(user, password: "password123")
      post session_url, params: { session: { phone_number: user.phone_number, password: password } }
    end
  end
end
