class Noswoop < Formula
  desc "Disable macOS space-switching animation"
  homepage "https://github.com/tahul/noswoop"
  url "https://github.com/tahul/noswoop/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "ee4ab6fa5df28cf9406c00429f99a945b6625335d10270bf8727bbf35ed06f38"
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
