import { Controller } from "@hotwired/stimulus"

// 계좌번호 원탭 복사 (F9 학부모 청구 페이지 — PRD 8장: 3초 안에 계좌 복사)
// 복사 값·안내 문구는 data-attribute(Stimulus value)로 뷰에서 전달하며,
// 클립보드 API 실패 시 표시 중인 계좌번호를 전체 선택해 복사를 유도하는 폴백을 제공한다.
export default class extends Controller {
  static targets = ["display", "toast"]
  static values = {
    text: String,
    successMessage: String,
    fallbackMessage: String
  }

  connect() {
    this.timer = null
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  copy() {
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(this.textValue)
        .then(() => this.showToast(this.successMessageValue))
        .catch(() => this.selectFallback())
    } else {
      this.selectFallback()
    }
  }

  // 폴백: 계좌번호 표시 영역 전체 선택 + 복사 안내 토스트
  selectFallback() {
    if (this.hasDisplayTarget) {
      const selection = window.getSelection()
      const range = document.createRange()
      range.selectNodeContents(this.displayTarget)
      selection.removeAllRanges()
      selection.addRange(range)
    }
    this.showToast(this.fallbackMessageValue)
  }

  showToast(message) {
    if (!this.hasToastTarget) return

    this.toastTarget.textContent = message
    this.toastTarget.classList.remove("hidden")
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.toastTarget.classList.add("hidden"), 2000)
  }
}
