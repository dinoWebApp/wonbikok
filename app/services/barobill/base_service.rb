# frozen_string_literal: true

module Barobill
  # 바로빌 API 오류 — 음수 오류코드·메시지 보관(어댑터 계약: 실패는 예외 대신 Result.failure)
  class Error < StandardError
    attr_reader :code

    def initialize(message = nil, code: nil)
      @code = code
      super(message)
    end
  end

  # 복합형 파라미터(CashBillEx 등)의 직렬화 완료 XML — escape 없이 삽입용
  RawXml = Data.define(:xml)

  # 바로빌 SOAP API 공통 베이스(직접 HTTP 통신 규격 — Net::HTTP + XML 엔벨로프).
  # savon 미채택(Ruby 4 호환 미확인) — PRD 10.2·01_plan §2.
  #
  # 환경 분기(PRD 10.2): production = release_auth_key + ws.baroservice.com /
  # 그 외 = test_auth_key + testws.baroservice.com (키·엔드포인트 쌍).
  # cert_key 공백 = SIMULATED 모드 — 외부 호출 없이 성공 응답 시뮬레이션(솔라피 패턴 준용).
  #
  # 통신 규격 근거: dev.barobill.co.kr "바로빌 API 개발준비 — 직접 HTTP 통신" (SOAP 1.1 엔벨로프,
  # POST text/xml, SOAPAction 헤더, 응답은 "<메서드>Response" 래퍼의 "<메서드>Result" 값).
  # ※ 공식 문서 페이지가 JS 렌더로 기계 열람이 불완전하여 메서드별 정확 파라미터 순서·
  #   복합형(CashBillEx) 자식 태그 규격은 스파이크(테스트키 1회)로 검증할 항목 — 03_implementation.md 참조.
  class BaseService
    API_HOST = "https://ws.baroservice.com"
    TEST_API_HOST = "https://testws.baroservice.com"
    XML_NS = "http://ws.baroservice.com/"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20

    NETWORK_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET,
                      Errno::ECONNREFUSED, OpenSSL::SSL::SSLError ].freeze

    # 어댑터 단일 응답 구조 — value는 메서드별(정수 코드·문자열 URL·해시 등)
    Result = Data.define(:success?, :code, :message, :value) do
      def self.ok(value:, code: nil)
        new(success?: true, code: code, message: nil, value: value)
      end

      def self.failure(code, message)
        new(success?: false, code: code, message: message, value: nil)
      end
    end

    # SIMULATED 응답 — 외부 호출 없이 성공 시뮬레이션(외부 상태는 3000 가정)
    SimulatedResult = Data.define(:success?, :code, :message, :value) do
      def self.ok(value: nil)
        new(success?: true, code: 3000, message: "SIMULATED", value: value)
      end
    end

    class << self
      # dev/test 기본은 SIMULATED(PRD 10.2·01_plan §1) — 실호출(스파이크)은 BAROBILL_LIVE=1로만 허용.
      def resolve_cert_key
        config = Rails.application.credentials
        key = Rails.env.production? ? config.dig(:barobill, :release_auth_key) : config.dig(:barobill, :test_auth_key)
        return "" unless Rails.env.production? || ENV["BAROBILL_LIVE"] == "1"

        # W8: production에서 release_auth_key 누락 시 조용한 SIMULATED 전환을 감지 가능하게 경보
        if Rails.env.production? && key.to_s.strip.blank?
          Rails.logger.warn("[Barobill] release_auth_key 미설정 — SIMULATED 모드로 동작합니다(실발행 없음)")
        end
        key.to_s
      end

      def from_credentials
        new(cert_key: resolve_cert_key)
      end

      # SIMULATED 여부 — cert_key 공백(미등록 환경)
      def simulated?(cert_key)
        cert_key.to_s.strip.blank?
      end
    end

    attr_reader :cert_key, :simulated

    def initialize(cert_key:)
      @cert_key = cert_key.to_s
      @simulated = self.class.simulated?(@cert_key)
    end

    def simulated?
      @simulated
    end

    private

    def api_host
      Rails.env.production? ? API_HOST : TEST_API_HOST
    end

    # SOAP 1.1 엔벨로프 구성 → POST → Result 파싱.
    # fields: [[name, value|Hash], ...] 순서 보존(WSDL 규격상 파라미터 순서 중요)
    def call(method_name, fields)
      return simulated_response(method_name, fields) if simulated?

      request_body = build_envelope(method_name, fields)
      response_body = post_xml(method_name, request_body)
      parse_result(method_name, response_body)
    rescue *NETWORK_ERRORS => e
      raise Error.new("NETWORK_ERROR: #{e.class.name}", code: :network_error)
    end

    def build_envelope(method_name, fields)
      params = fields.map { |name, value| param_xml(name, value) }.join
      <<~XML.strip
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns="#{XML_NS}">
          <soap:Body>
            <ns:#{method_name}>#{params}</ns:#{method_name}>
          </soap:Body>
        </soap:Envelope>
      XML
    end

    # 스칼라 파라미터와 복합형(RawXml — CashBillEx 등) 공용 직렬화
    def param_xml(name, value)
      return "<ns:#{name}>#{value.xml}</ns:#{name}>" if value.is_a?(RawXml)

      escaped = CGI.escapeHTML(value.to_s)
      "<ns:#{name}>#{escaped}</ns:#{name}>"
    end

    def post_xml(method_name, body)
      uri = URI("#{api_host}/CASHRECEIPT.SVC")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "text/xml; charset=utf-8"
      request["SOAPAction"] = "#{XML_NS}#{method_name}"
      request.body = body

      response = http.request(request)
      raise Error.new("HTTP_#{response.code}", code: "HTTP_#{response.code}") unless response.is_a?(Net::HTTPSuccess)

      response.body.to_s
    end

    # "<메서드>Response" 래퍼 내 "<메서드>Result" 텍스트 추출 → 부정수는 오류코드.
    # 복합형 응답(GetCashBillInfo 등)은 raw_result_doc 경유로 추가 노드를 읽는다.
    def parse_result(method_name, response_body)
      parse_doc(method_name, Nokogiri::XML(response_body) { |config| config.strict })
    end

    def parse_doc(method_name, doc)
      result_node = doc.at_xpath("//*[local-name()='#{method_name}Result']")
      raise Error.new("INVALID_RESPONSE: Result 노드 없음", code: :invalid_response) if result_node.nil?

      code = result_node.text.to_s.strip
      return Result.ok(value: code) unless negative_code?(code)

      Result.failure(code.to_i, error_message_for(code.to_i))
    rescue Nokogiri::XML::SyntaxError, ArgumentError
      raise Error.new("INVALID_RESPONSE: XML 파싱 실패", code: :invalid_response)
    end

    # 복합형 응답용 — 엔벨로프 전체 문서 반환(파싱은 호출자). SIMULATED 시 nil.
    def raw_result_doc(method_name, fields)
      return nil if simulated?

      body = post_xml(method_name, build_envelope(method_name, fields))
      Nokogiri::XML(body) { |config| config.strict }
    rescue Nokogiri::XML::SyntaxError
      raise Error.new("INVALID_RESPONSE: XML 파싱 실패", code: :invalid_response)
    end

    def negative_code?(code)
      code.match?(/\A-\d+\z/)
    end

    # 공통 오류코드 표기(상세는 dev.barobill.co.kr 오류코드 조회) — 코드 원본 보존
    def error_message_for(code)
      I18n.t("barobill.errors.#{code}", default: I18n.t("barobill.errors.default", code: code))
    end

    # SIMULATED — 메서드별 시뮬레이션 성공 응답(외부 호출 없음, 서브클래스가 값 정의)
    def simulated_response(method_name, _fields)
      SimulatedResult.ok(value: simulated_value_for(method_name))
    end

    def simulated_value_for(method_name)
      nil
    end
  end
end
