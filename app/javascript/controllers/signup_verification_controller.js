import { Controller } from "@hotwired/stimulus"

// 가입 휴대폰 인증 단계 UI (F10 REF-006 — 발송 → 코드 입력 → 검증 완료 표시).
// - 서버가 원천(signup_verifications): 가입 create는 검증 완료 레코드 소비를 서버 재검증하므로
//   본 컨트롤러는 표현·편의만 담담(Stimulus는 UI 표현만 — 상태 최소화).
// - 문구는 뷰에서 ko.yml로 주입(messages 값) — 하드코딩 금지.
// - fetch 실패·네트워크 오류 시 공통 오류 문구 표시 + 발송 버튼 재활성화.
export default class extends Controller {
  static targets = ["phoneInput", "sendButton", "codeSection", "codeInput", "verifyButton", "statusArea"]
  static values = {
    sendUrl: String,
    verifyUrl: String,
    messages: Object
  }

  connect() {
    this.setBusy(this.sendButtonTarget, false)
  }

  async sendCode() {
    const phone = this.phoneInputTarget.value.trim()
    if (!phone) {
      this.showMessage(this.messagesValue.phone_required, "error")
      return
    }

    this.setBusy(this.sendButtonTarget, true)
    this.showMessage("", "idle")
    try {
      const data = await this.postJson(this.sendUrlValue, { phone_number: phone })
      if (data.status === "ok") {
        this.codeSectionTarget.classList.remove("hidden")
        this.showMessage(data.message, "success")
        this.codeInputTarget.focus()
      } else {
        this.showMessage(data.message, "error")
      }
    } catch {
      this.showMessage(this.messagesValue.send_failed, "error")
    } finally {
      this.setBusy(this.sendButtonTarget, false)
    }
  }

  async verifyCode() {
    const phone = this.phoneInputTarget.value.trim()
    const code = this.codeInputTarget.value.trim()
    if (!code) {
      this.showMessage(this.messagesValue.code_required, "error")
      return
    }

    this.setBusy(this.verifyButtonTarget, true)
    try {
      const data = await this.postJson(this.verifyUrlValue, { phone_number: phone, code: code })
      if (data.status === "ok") {
        this.markVerified(data.message)
      } else {
        this.showMessage(data.message, "error")
      }
    } catch {
      this.showMessage(this.messagesValue.send_failed, "error")
    } finally {
      this.setBusy(this.verifyButtonTarget, false)
    }
  }

  // 코드 입력에서 Enter로 검증 실행
  submitOnEnter(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.verifyCode()
    }
  }

  markVerified(message) {
    this.showMessage(message, "success")
    this.codeInputTarget.readOnly = true
    this.verifyButtonTarget.disabled = true
    this.verifyButtonTarget.classList.add("opacity-60")
    this.sendButtonTarget.disabled = true
    this.sendButtonTarget.classList.add("opacity-60")
  }

  async postJson(url, body) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token,
        Accept: "application/json"
      },
      body: JSON.stringify(body)
    })
    return response.json()
  }

  showMessage(message, kind) {
    if (!this.hasStatusAreaTarget) return
    this.statusAreaTarget.textContent = message
    this.statusAreaTarget.classList.remove("hidden")
    this.statusAreaTarget.classList.toggle("text-danger-700", kind === "error")
    this.statusAreaTarget.classList.toggle("text-success-700", kind === "success")
  }

  setBusy(button, busy) {
    button.disabled = busy
    button.classList.toggle("opacity-60", busy)
  }
}
