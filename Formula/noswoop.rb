class Noswoop < Formula
  desc "Disable macOS space-switching animation"
  homepage "https://github.com/tahul/noswoop"
  url "https://github.com/tahul/noswoop/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "8984a67b5ad849a4bc0e55a60d1f7c7d55f09ef80de0cf9e843e28dd64698cf4"
  license "Unlicense"

  depends_on :macos

  def install
    system "make", "build"
    bin.install "noswoop"
  end

  service do
    run [opt_bin/"noswoop"]
    keep_alive true
    log_path var/"log/noswoop.log"
    error_log_path var/"log/noswoop.log"
  end

  def caveats
    <<~EOS
      noswoop requires Accessibility permissions.
      Grant access in: System Settings → Privacy & Security → Accessibility

      To start noswoop as a background service:
        brew services start noswoop
    EOS
  end

  test do
    assert_match "accessibility permission required", shell_output("#{bin}/noswoop 2>&1", 1)
  end
end
