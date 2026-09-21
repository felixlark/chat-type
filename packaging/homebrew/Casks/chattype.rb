cask "chattype" do
  version "0.5.1"
  sha256 :no_check

  url "https://github.com/felixlark/chat-type/releases/download/v#{version}/ChatType-#{version}-macos-arm64.zip"
  name "ChatType"
  desc "Push-to-talk macOS dictation for signed-in ChatGPT desktop users"
  homepage "https://github.com/felixlark/chat-type"

  depends_on macos: ">= :ventura"

  app "ChatType.app"
end
